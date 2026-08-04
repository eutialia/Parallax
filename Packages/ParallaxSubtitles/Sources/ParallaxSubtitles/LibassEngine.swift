import Foundation
import Libass

/// Owns the three libass handles for their whole lifetime.
///
/// They exist as a class rather than as actor properties for one reason: an
/// actor's `deinit` is not isolated and so cannot touch non-Sendable stored
/// properties such as `OpaquePointer`. A plain class has no such restriction, so
/// the handles are freed here, in the right order, exactly once — no unchecked
/// Sendable conformance and no unsafe opt-out anywhere.
///
/// The instance is deliberately NOT Sendable: it is created by, stored in, and
/// only ever touched by `SubtitleRenderer`, which is an actor. libass' own
/// objects are not thread safe, and that confinement is what makes them safe.
final class LibassEngine {

    let library: OpaquePointer
    let renderer: OpaquePointer
    private(set) var track: UnsafeMutablePointer<ASS_Track>?

    /// libass' own diagnostics (font selection, parse complaints), captured via the
    /// message callback instead of the default stderr spam. Font problems are
    /// invisible in the output bitmap — a missing glyph renders as a perfectly
    /// valid tofu box — so this log is the only ground truth for "which font did
    /// libass actually use". Ring-buffered; confined to the owning actor like
    /// every other libass structure here.
    final class MessageLog {
        private(set) var lines: [String] = []
        func append(level: Int32, message: String) {
            if lines.count >= 400 { lines.removeFirst(100) }
            lines.append("[\(level)] \(message)")
        }
    }

    let messageLog = MessageLog()

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

    init?(defaultFontFamily: String, defaultFontPath: String? = nil) {
        // Allocated first so a failure here needs no libass teardown.
        guard let overrideStyleName = strdup("Default") else { return nil }
        guard let library = ass_library_init() else {
            free(overrideStyleName)
            return nil
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            free(overrideStyleName)
            return nil
        }
        self.overrideStyleName = overrideStyleName
        self.library = library
        self.renderer = renderer

        // Route libass' messages (stderr by default) into the ring buffer. The
        // callback context is a raw pointer to `messageLog`; libass only invokes
        // the callback synchronously inside calls we make from the owning actor,
        // and the engine (which retains the log) outlives the library handle.
        ass_set_message_cb(
            library,
            { level, format, args, context in
                guard let format, let context, level <= 6 else { return }
                var buffer = [CChar](repeating: 0, count: 512)
                if let args {
                    vsnprintf(&buffer, buffer.count, format, args)
                } else {
                    strlcpy(&buffer, format, buffer.count)
                }
                let log = Unmanaged<MessageLog>.fromOpaque(context).takeUnretainedValue()
                log.append(level: level, message: String(cString: buffer))
            },
            Unmanaged.passUnretained(messageLog).toOpaque()
        )

        // CoreText for system faces, plus an optional default font FILE — the
        // last-resort face for glyphs no openable system font covers. Needed
        // because CoreText's CJK fallback answer is PingFang, whose modern
        // container FreeType cannot parse ("loca table missing") — without a
        // readable default, every Chinese-first run renders as tofu.
        defaultFontFamily.withCString { family in
            if let defaultFontPath {
                defaultFontPath.withCString { path in
                    ass_set_fonts(renderer, path, family, Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
                }
            } else {
                ass_set_fonts(renderer, nil, family, Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
            }
        }
        // Hinting fights smooth scaling and breaks positioned scripts.
        ass_set_hinting(renderer, ASS_HINTING_NONE)
    }

    deinit {
        // Reverse of creation: both the track and the renderer reference the library.
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        ass_library_done(library)
        // Only safe once the renderer is gone: it held this pointer, not a copy.
        free(overrideStyleName)
    }

    /// Parses a script and, only if it yielded events, swaps it in for the current one.
    func loadTrack(bytes: inout [UInt8]) throws {
        // ass_read_memory takes a mutable buffer and copies whatever it keeps.
        let loaded: UnsafeMutablePointer<ASS_Track>? = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                ass_read_memory(library, chars, buffer.count, nil)
            }
        }

        guard let loaded else { throw SubtitleError.noCues }
        guard loaded.pointee.n_events > 0 else {
            ass_free_track(loaded)
            throw SubtitleError.noCues
        }

        if let track { ass_free_track(track) }
        track = loaded
    }
}
