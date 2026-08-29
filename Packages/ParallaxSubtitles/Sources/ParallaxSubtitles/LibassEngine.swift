import CoreGraphics
import Foundation
import Libass

/// The one `ASS_Library` this process ever creates, and the one lock that guards
/// every libass call made through it.
///
/// Memory fonts live on the LIBRARY, not on the renderer: `ass_add_font` memcpy's
/// the blob into the library and the embedded font provider then indexes that copy
/// for every renderer built against it. The bundle is ~50 MB across 37 files, so a
/// library per `SubtitleRenderer` meant a ~50 MB copy plus a full re-parse of fifty
/// faces on every subtitle pick. One library, registered once, removes that cost entirely —
/// `ass_renderer_init` and `ass_read_memory` both take the library and the header
/// explicitly contemplates several `ASS_Renderer`/`ASS_Track` instances per library
/// (see `ass_clear_fonts`' precondition).
///
/// The price is that `ass_library_done` can never be called: the library outlives
/// every renderer, for the life of the process. That is deliberate, and it is why
/// `ass_clear_fonts` must never be called either.
///
/// **Invariant: font extraction stays off.** `ass_set_extract_fonts` is never
/// called, so `library->extract_fonts` keeps the zero `ass_library_init`'s
/// `calloc` gives it — and libass 0.17.5's `decode_font` (`ass.c`) only calls
/// `ass_add_font` for a script's `[Fonts]` attachments when that flag is set.
/// A shared library therefore CANNOT accumulate one track's embedded faces and
/// leak them into the next renderer's `fontselect`; the candidate set is the
/// bundled Noto files, always, which is the whole point of
/// `ASS_FONTPROVIDER_NONE`.
/// Turning extraction on would need a per-track `ass_clear_fonts`, which this
/// design has no place to run — so it stays off.
final class LibassLibrary: @unchecked Sendable {

    static let shared = LibassLibrary()

    /// libass has no internal synchronisation, and sharing the library makes two
    /// renderers' calls meet inside it: `library->fontdata` is read lazily by
    /// every renderer's `fontselect` (FreeType opens faces straight out of that
    /// array on first use), and the message callback is per library, so message
    /// ROUTING is only unambiguous while one call is in flight. Rather than
    /// reason case-by-case about which pairs can overlap, EVERY libass call in
    /// this package runs under this one lock — including `ass_render_frame`. It
    /// is a few hundred microseconds of critical section against at most two live
    /// renderers (player overlay + settings preview), which is not a contention
    /// problem worth a finer scheme.
    ///
    /// Recursive because the message callback re-enters it: libass invokes the
    /// callback synchronously, on the thread already inside a locked call.
    private let lock = NSRecursiveLock()

    private var handle: OpaquePointer?
    private var initFailed = false
    private var bootstrapDuration: Duration?

    /// File names already handed to `ass_add_font`. Add-only: `ass_clear_fonts`
    /// cannot be called on a shared library (its precondition is that every
    /// track and renderer is gone), so a registration is permanent.
    private var registeredFiles: Set<String> = []

    /// Bumped by every registration. A renderer built before the bump has a
    /// `fontselect` that snapshotted the old set — `ass_set_fonts` is what
    /// re-reads the library's font data — so this is how one knows to re-run it.
    private var fontGeneration = 0

    /// The renderer whose log the messages of the call in flight belong to.
    /// `ass_set_message_cb` is per LIBRARY, so with one shared library the only
    /// way to keep `SubtitleRenderer.diagnosticLog` per renderer is to route on
    /// "who is currently inside libass" — which the lock makes unambiguous.
    private var currentLog: LibassEngine.MessageLog?

    /// Where the one-time bootstrap's own chatter goes, so that whichever renderer
    /// happens to trigger it does not inherit lines the others never see.
    let bootstrapLog = LibassEngine.MessageLog()

    private init() {}

    /// Wall time the one-time library bootstrap cost, once it has happened.
    /// Diagnostic only — the latency guard test prints it.
    var bootstrapCost: Duration? {
        lock.lock()
        defer { lock.unlock() }
        return bootstrapDuration
    }

    /// Runs `body` against the shared library with every message libass emits
    /// inside it appended to `log`. Returns nil only when the library could not
    /// be created at all.
    func perform<T>(
        log: LibassEngine.MessageLog?,
        _ body: (OpaquePointer) throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let library = bootstrappedHandle() else { return nil }
        let previous = currentLog
        currentLog = log
        defer { currentLog = previous }
        return try body(library)
    }

    /// Registers any of `files` libass has not been given yet, and returns the
    /// resulting font generation.
    ///
    /// Called from `SubtitleRenderer.load` once the track's routing is known and
    /// BEFORE the renderer's `ass_set_fonts`, which is where `fontselect`
    /// snapshots the library's font data. Registering is permanent and costs a
    /// memcpy of the file (the pan-CJK collections are 19 and 26 MB), so it is
    /// deliberately driven by what a real track asks for rather than by what the
    /// bundle contains.
    @discardableResult
    func ensureRegistered(files: [URL], log: LibassEngine.MessageLog? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let library = bootstrappedHandle() else { return fontGeneration }
        let wanted = files.filter { !registeredFiles.contains($0.lastPathComponent) }
        guard !wanted.isEmpty else { return fontGeneration }

        let previous = currentLog
        currentLog = log
        defer { currentLog = previous }
        register(SubtitleFontBundle.registrations(for: wanted), into: library)
        return fontGeneration
    }

    /// The current font generation, read under the lock.
    var currentFontGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return fontGeneration
    }

    /// Files libass has been given, for tests that pin the lazy-registration
    /// contract. Never a decision input: `ensureRegistered` is the only reader
    /// that matters.
    var registeredFileNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return registeredFiles
    }

    /// `perform` for a body that is itself optional. The library's "could not
    /// init" nil and the body's own nil mean the same thing to every caller in
    /// this file — an operation that produced nothing — so they flatten rather
    /// than nest into `T??`.
    func performOptional<T>(
        log: LibassEngine.MessageLog?,
        _ body: (OpaquePointer) throws -> T?
    ) rethrows -> T? {
        try perform(log: log, body) ?? nil
    }

    /// Caller holds the lock.
    private func bootstrappedHandle() -> OpaquePointer? {
        if let handle { return handle }
        guard !initFailed else { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        guard let library = ass_library_init() else {
            initFailed = true
            return nil
        }

        // Route libass' messages (stderr by default) into whichever ring buffer
        // owns the call in flight. The callback carries no context: the library
        // is a singleton and the routing target is the lock-guarded `currentLog`.
        ass_set_message_cb(
            library,
            { level, format, args, _ in
                guard let format, level <= 6 else { return }
                var buffer = [CChar](repeating: 0, count: 512)
                if let args {
                    vsnprintf(&buffer, buffer.count, format, args)
                } else {
                    strlcpy(&buffer, format, buffer.count)
                }
                LibassLibrary.shared.appendToCurrentLog(
                    level: level,
                    message: String(validating: buffer.prefix { $0 != 0 }, as: UTF8.self) ?? ""
                )
            },
            nil
        )

        currentLog = bootstrapLog
        register(
            SubtitleFontBundle.registrations(for: SubtitleFontBundle.latinFileURLs),
            into: library
        )
        currentLog = nil

        bootstrapDuration = clock.now - start
        handle = library
        return library
    }

    /// Hands libass a set of files as memory fonts. libass' embedded provider
    /// iterates every face of a collection (`process_fontdata` reads
    /// `face->num_faces` and loops), so one call per file indexes all of a TTC's
    /// regional families under their own names. The files are mapped, not read:
    /// `ass_add_font` copies what it keeps, so the mapping can go away the
    /// moment this returns.
    ///
    /// Caller holds the lock.
    private func register(_ fonts: [(name: String, data: Data)], into library: OpaquePointer) {
        for font in fonts where registeredFiles.insert(font.name).inserted {
            font.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                ass_add_font(
                    library, font.name,
                    base.assumingMemoryBound(to: CChar.self), Int32(bytes.count)
                )
            }
            fontGeneration += 1
        }
    }

    fileprivate func appendToCurrentLog(level: Int32, message: String) {
        lock.lock()
        defer { lock.unlock() }
        currentLog?.append(level: level, message: message)
    }
}

/// Owns the per-renderer libass handles for their whole lifetime.
///
/// They exist as a class rather than as actor properties for one reason: an
/// actor's `deinit` is not isolated and so cannot touch non-Sendable stored
/// properties such as `OpaquePointer`. A plain class has no such restriction, so
/// the handles are freed here, in the right order, exactly once — no unchecked
/// Sendable conformance and no unsafe opt-out anywhere.
///
/// The instance is deliberately NOT Sendable: it is created by, stored in, and
/// only ever touched by `SubtitleRenderer`, which is an actor. The `ASS_Library`
/// it renders against is shared process-wide (`LibassLibrary`), so every call
/// reaching libass — including per-frame rendering — goes through
/// `LibassLibrary.perform`, which serialises it and tags its messages.
final class LibassEngine {

    let renderer: OpaquePointer
    private(set) var track: UnsafeMutablePointer<ASS_Track>?

    /// libass' own diagnostics (font selection, parse complaints), captured via the
    /// message callback instead of the default stderr spam. Font problems are
    /// invisible in the output bitmap — a missing glyph renders as a perfectly
    /// valid tofu box — so this log is the only ground truth for "which font did
    /// libass actually use". Ring-buffered; only ever written while the shared
    /// library lock is held, and only by calls this engine made.
    final class MessageLog {
        private(set) var lines: [String] = []
        func append(level: Int32, message: String) {
            if lines.count >= 400 { lines.removeFirst(100) }
            lines.append("[\(level)] \(message)")
        }
    }

    let messageLog: MessageLog

    /// The `Name` buffer for `ass_set_selective_style_override`, alive as long as
    /// the renderer is.
    ///
    /// The header claims that function copies its strings, and for `FontName` it
    /// does. It does NOT for `Name`: 0.17.5 stores that pointer raw and
    /// `ass_renderer_done` never frees it either (both confirmed by disassembling
    /// the shipped archive, not inferred from the docs). So this buffer is ours to
    /// keep and ours to release — freeing it right after the call, which the
    /// header implies is safe, would leave libass holding a dangling pointer.
    let overrideStyleName: UnsafeMutablePointer<CChar>

    private let defaultFontFamily: String
    /// The library font generation this renderer's `fontselect` was built
    /// against. Fonts registered after it are invisible until `ass_set_fonts`
    /// runs again.
    private var fontGeneration: Int

    init?(defaultFontFamily: String) {
        // Allocated first so a failure here needs no libass teardown.
        guard let overrideStyleName = strdup("Default") else { return nil }
        let log = MessageLog()
        guard let built = Self.makeRenderer(log: log, defaultFontFamily: defaultFontFamily) else {
            free(overrideStyleName)
            return nil
        }
        self.overrideStyleName = overrideStyleName
        self.messageLog = log
        self.renderer = built.renderer
        self.fontGeneration = built.generation
        self.defaultFontFamily = defaultFontFamily
    }

    deinit {
        // The library is NOT torn down here — it is process-wide and outlives
        // every engine. Only what this engine created is freed, and the track
        // goes first because it references the renderer's library.
        //
        // On a detached task, not here: `deinit` runs on whatever thread happens
        // to drop the last reference — a render loop, the main actor — and
        // taking the process-wide libass lock there blocks that thread behind
        // whichever renderer is mid-frame. Nothing else can reach these handles
        // once deinit has begun, so moving them is safe by construction.
        Teardown(
            track: track, renderer: renderer, overrideStyleName: overrideStyleName
        ).schedule()
    }

    /// The handles a dropped engine still owes libass.
    ///
    /// `@unchecked Sendable` for one reason: these pointers are unreachable from
    /// anywhere else the moment `deinit` starts, so handing them to one detached
    /// task transfers sole ownership — the guarantee the compiler cannot see
    /// through an `OpaquePointer`.
    private struct Teardown: @unchecked Sendable {
        let track: UnsafeMutablePointer<ASS_Track>?
        let renderer: OpaquePointer
        let overrideStyleName: UnsafeMutablePointer<CChar>

        func schedule() {
            Task.detached(priority: .utility) {
                _ = LibassLibrary.shared.perform(log: nil) { _ in
                    if let track { ass_free_track(track) }
                    ass_renderer_done(renderer)
                }
                // Only safe once the renderer is gone: it held this pointer,
                // not a copy.
                free(overrideStyleName)
            }
        }
    }

    /// Builds a renderer against the shared library and configures its fonts.
    ///
    /// `ASS_FONTPROVIDER_NONE`: no CoreText, no system face reachable from any
    /// path — the whole point of bundling. It is also why every run is tagged:
    /// nothing catches a script the named family cannot draw. The embedded provider holding the
    /// library's memory fonts is built unconditionally by `ass_fontselect_init`,
    /// before the provider switch is even read, so this disables the OS and
    /// nothing else. `default_font` is a FILE and must be supplied when every
    /// system provider is off; it is the last resort under `default_family`.
    ///
    /// `fontselect` is per RENDERER, so `ass_set_fonts` still has to run for each
    /// one — but it now only indexes font data the library already owns instead
    /// of copying ~50 MB, which is what makes a second renderer cheap.
    private static func makeRenderer(
        log: MessageLog,
        defaultFontFamily: String
    ) -> (renderer: OpaquePointer, generation: Int)? {
        return LibassLibrary.shared.performOptional(log: log) { library in
            guard let renderer = ass_renderer_init(library) else { return nil }
            setFonts(on: renderer, defaultFontFamily: defaultFontFamily)
            // Hinting fights smooth scaling and breaks positioned scripts.
            ass_set_hinting(renderer, ASS_HINTING_NONE)
            return (renderer, LibassLibrary.shared.currentFontGeneration)
        }
    }

    /// Caller is inside `LibassLibrary.perform`.
    private static func setFonts(on renderer: OpaquePointer, defaultFontFamily: String) {
        defaultFontFamily.withCString { family in
            if let path = SubtitleFontBundle.defaultFontPath {
                path.withCString { path in
                    ass_set_fonts(
                        renderer, path, family,
                        Int32(ASS_FONTPROVIDER_NONE.rawValue), nil, 1
                    )
                }
            } else {
                ass_set_fonts(
                    renderer, nil, family,
                    Int32(ASS_FONTPROVIDER_NONE.rawValue), nil, 1
                )
            }
        }
    }

    /// Re-runs `ass_set_fonts` when the library has gained fonts since this
    /// renderer's `fontselect` was built — otherwise a face registered for the
    /// track about to load would be invisible to it, which is the same tofu the
    /// bundle exists to prevent.
    func refreshFontsIfNeeded() {
        let generation = LibassLibrary.shared.currentFontGeneration
        guard generation != fontGeneration else { return }
        _ = LibassLibrary.shared.perform(log: messageLog) { _ in
            Self.setFonts(on: renderer, defaultFontFamily: defaultFontFamily)
        }
        fontGeneration = generation
    }

    /// Runs `body` on this engine's renderer under the shared library lock, with
    /// libass' messages routed to this engine's log. The renderer's existence
    /// proves the library exists, so this never fails.
    @discardableResult
    func withRenderer<T>(_ body: (OpaquePointer) -> T) -> T? {
        LibassLibrary.shared.perform(log: messageLog) { _ in body(renderer) }
    }

    func renderFrame(atMilliseconds time: Int64, changed: inout Int32) -> UnsafeMutablePointer<ASS_Image>? {
        LibassLibrary.shared.performOptional(log: messageLog) { _ in
            ass_render_frame(renderer, track, time, &changed)
        }
    }

    /// The loaded track's canvas, with libass' own inference for a dimension the
    /// script left out (`ASSPlayRes`). Nil until a track parses. Script-unit
    /// lengths — border, shadow, margins — only mean anything against this.
    var trackPlayRes: CGSize? {
        guard let track else { return nil }
        return ASSPlayRes.effective(x: Int(track.pointee.PlayResX), y: Int(track.pointee.PlayResY))
    }

    /// Parses a script and, only if it yielded events, swaps it in for the current one.
    func loadTrack(bytes: inout [UInt8]) throws {
        // ass_read_memory takes a mutable buffer and copies whatever it keeps.
        // A script's [Fonts] attachments do NOT reach the shared library: font
        // extraction is off (see LibassLibrary), so the candidate set stays the
        // bundle's for every renderer.
        let parsed = LibassLibrary.shared.performOptional(log: messageLog) { library in
            bytes.withUnsafeMutableBufferPointer { buffer -> UnsafeMutablePointer<ASS_Track>? in
                guard let base = buffer.baseAddress else { return nil }
                return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                    ass_read_memory(library, chars, buffer.count, nil)
                }
            }
        }

        guard let loaded = parsed else { throw SubtitleError.noCues }
        guard loaded.pointee.n_events > 0 else {
            _ = LibassLibrary.shared.perform(log: messageLog) { _ in ass_free_track(loaded) }
            throw SubtitleError.noCues
        }

        if let track {
            _ = LibassLibrary.shared.perform(log: messageLog) { _ in ass_free_track(track) }
        }
        track = loaded
    }
}
