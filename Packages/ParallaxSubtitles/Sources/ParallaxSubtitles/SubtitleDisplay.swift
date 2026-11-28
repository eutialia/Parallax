import Foundation
import Observation
import os

/// A subtitle document the app fetches whole: a sidecar file on a share, or a stream a server
/// extracts. The URL is its identity for the session.
public struct SubtitleDocument: Hashable, Sendable {
    public let url: URL
    /// The track's own language label, when known. See `SubtitleRenderer.load`.
    public let languageCode: String?

    public init(url: URL, languageCode: String?) {
        self.url = url
        self.languageCode = languageCode
    }
}

/// What one request for a subtitle document brought back.
public enum SubtitleFetchOutcome: Sendable {
    case data(Data)
    /// No answer in time: the server is still extracting the stream, and a later request is
    /// served from its cache.
    case notReady
    /// An error status, an empty body, or no connection.
    case rejected
}

/// What the renderer on screen was loaded with. The debug panel shows it, and the style push
/// keys off `format`: SRT/VTT carry no authored look, so the user's style always applies;
/// ASS/SSA keeps its creator's, always.
public struct SidecarSubtitleInfo: Equatable, Sendable {
    public let format: SubtitleSourceFormat
    public let byteCount: Int

    public init(format: SubtitleSourceFormat, byteCount: Int) {
        self.format = format
        self.byteCount = byteCount
    }
}

extension SubtitleSourceFormat {
    /// Maps a file or URL extension to the renderer's ingest format. Anything unrecognized is
    /// treated as WebVTT: Jellyfin's conversion fallback serves VTT for every format that is
    /// not requested verbatim.
    public init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "ass": self = .ass
        case "ssa": self = .ssa
        case "srt": self = .srt
        default: self = .vtt
        }
    }
}

/// The subtitle the app draws itself: the fetch that turns a document into bytes (cached for the
/// session), the libass renderer built from them, and the user's style pushed onto it. Which
/// subtitle is selected is the player's call; this only draws it.
@Observable
@MainActor
public final class SubtitleDisplay {
    /// A renderer that is up and drawing, with what it was built from.
    private struct Installed {
        let renderer: SubtitleRenderer
        let info: SidecarSubtitleInfo
        /// The raw payload, kept so a font-design change can REBUILD the renderer: the CJK
        /// `\fn` tags and font plan are baked at load against the style family, so a new
        /// family needs a fresh load, not a style push.
        let data: Data
        let languageCode: String?
        /// The family the renderer was built around.
        let family: String
    }
    private var installed: Installed?

    /// The renderer for the subtitle on screen, or nil when the app draws none.
    public var renderer: SubtitleRenderer? { installed?.renderer }
    public var shownInfo: SidecarSubtitleInfo? { installed?.info }
    /// Monotonic token bumped on every renderer install/clear. The overlay keys its
    /// canvas pushes on this instead of object identity — a freed actor's address can
    /// be reused by its replacement, which would silently skip the new canvas push
    /// and leave the fresh renderer with a zero canvas (permanently blank subtitles).
    public private(set) var rendererGeneration = 0

    private let fetch: @Sendable (URL) async -> SubtitleFetchOutcome

    private var fetchTask: Task<Void, Never>?

    /// The document the live `fetchTask` FETCH belongs to; nil once its install lands or fails
    /// (or when the slot holds a same-document style rebuild). Guards the rebuild path:
    /// cancelling another document's in-flight fetch to rebuild from the INSTALLED payload
    /// would reinstall the old subtitle under the new selection, and nothing would ever fetch
    /// the picked one.
    private var fetching: SubtitleDocument?
    /// The pick the view announced on the tap's own turn, before the async pick can start its
    /// fetch. It lives only until that pick returns (`disarmFetchIndicator`), so it can never
    /// outlast a pick that fetched nothing.
    private var armed: SubtitleDocument?
    /// The document the loading affordance spins on.
    public var loading: SubtitleDocument? {
        armed ?? fetching
    }
    /// Told when a load didn't land (no answer, an error, or bytes that don't parse), so the
    /// player can put its selection back.
    public var onFailed: (@MainActor (SubtitleDocument) -> Void)?
    /// Told when a load's renderer is installed and drawing: the pick has landed.
    public var onLanded: (@MainActor (SubtitleDocument) -> Void)?
    /// Last appearance pushed by the overlay (`applyAppearance`) — replayed onto every
    /// freshly loaded CONVERTED renderer so a subtitle switch keeps the user's style. Its
    /// fontScale remaps the tuned per-device size onto the synthesized script's base, which
    /// only means anything for a script we wrote.
    private var convertedAppearance: SubtitleStyleOverride?
    /// Session cache of fetched bytes, by URL. The expensive part of a first pick is the server
    /// extracting an embedded stream through ffmpeg; re-selecting a subtitle must never pay that
    /// twice. Dropped with the rest of the session state.
    private var cache: [URL: (data: Data, format: SubtitleSourceFormat)] = [:]

    /// Serializes renderer style pushes: rapid preference edits must land on the actor
    /// in submission order or the renderer can finish on a stale style.
    private var stylePushChain: Task<Void, Never>?

    // ParallaxCore's `Log` is out of reach: this package links nothing but libass, so the
    // app's one subsystem is spelled here.
    private static let log = Logger(subsystem: "com.lhdev.parallax", category: "playback")

    public init(fetch: @escaping @Sendable (URL) async -> SubtitleFetchOutcome) {
        self.fetch = fetch
    }

    isolated deinit {
        fetchTask?.cancel()
        stylePushChain?.cancel()
    }

    /// Show the loading affordance for a pick that is about to fetch: nothing for a document
    /// already in the session cache, whose pick is instant.
    public func armFetchIndicator(for document: SubtitleDocument) {
        guard cache[document.url] == nil else { return }
        armed = document
    }

    /// The pick `armFetchIndicator` announced has returned: whatever it started holds the slot itself.
    public func disarmFetchIndicator(for document: SubtitleDocument) {
        if armed == document { armed = nil }
    }

    /// Fetches `document` and loads it into a fresh `SubtitleRenderer`. Cancels any in-flight
    /// fetch first so a slow/stale load can't land on screen after a newer pick. Format comes
    /// from the URL extension: the Jellyfin endpoint serves originals for formats requested
    /// verbatim (ass/ssa/srt keep their authored styling and positioning), and an SMB sibling
    /// is whatever the release shipped.
    public func show(_ document: SubtitleDocument) {
        fetchTask?.cancel()
        let url = document.url
        if let cached = cache[url] {
            fetching = nil
            // Already fetched this session: no round trip, and — for an EMBEDDED
            // Jellyfin stream — no second ffmpeg extraction. Skip the loading state
            // too; the only cost left is the libass parse.
            fetchTask = Task { [weak self] in
                await self?.land(cached.data, format: cached.format, document: document)
            }
            return
        }
        // The first request is the only one the happy path pays: the verbatim
        // ass/ssa URL is what the renderer wants, and the VTT conversion below runs
        // ONLY when the server rejects it. Re-picking never re-pays either — the
        // bytes are cached above.
        fetching = document
        let fetch = fetch
        let requestedFormat = SubtitleSourceFormat(fileExtension: url.pathExtension)
        fetchTask = Task { [weak self] in
            var outcome = await fetch(url)
            var format = requestedFormat
            // A verbatim ass/ssa request can be rejected server-side (the endpoint only has
            // writers for some formats, and an embedded SSA track extracts as .ass) —
            // degrade to the server's VTT conversion: authored styling is lost, but
            // the track still shows instead of nothing. Not after `notReady`: the server is
            // still extracting, and a second request would only wait on the same work.
            if case .rejected = outcome, format == .ass || format == .ssa,
               let fallback = Self.vttFallbackURL(for: url) {
                outcome = await fetch(fallback)
                format = .vtt
            }
            if Task.isCancelled { return }
            guard case .data(let data) = outcome else {
                self?.fail(document)
                return
            }
            self?.cache[url] = (data, format)
            await self?.land(data, format: format, document: document)
        }
    }

    private func land(_ data: Data, format: SubtitleSourceFormat, document: SubtitleDocument) async {
        if await install(data: data, format: format, languageCode: document.languageCode) {
            onLanded?(document)
        } else if !Task.isCancelled {
            fail(document)
        }
    }

    /// The CURRENT pick didn't land: leaving the previous subtitle's bitmaps on screen would lie
    /// about what's selected, so nothing stays drawn until the player restores what it can.
    private func fail(_ document: SubtitleDocument) {
        clear()
        onFailed?(document)
    }

    /// Same URL with the last path component's extension swapped to `vtt` — the
    /// Jellyfin sidecar endpoint's conversion fallback. The query (auth) is preserved.
    private static func vttFallbackURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path as NSString
        guard !path.pathExtension.isEmpty else { return nil }
        components.path = path.deletingPathExtension.appending(".vtt")
        return components.url
    }

    /// Builds + publishes the renderer for fetched bytes. A fresh renderer per
    /// load keeps subtitle switches simple (no cross-track libass state); the overlay
    /// detects the swap via `rendererGeneration`. Undecodable data is logged and
    /// reported as `false`; the caller decides what a failed load undoes.
    private func install(
        data: Data,
        format: SubtitleSourceFormat,
        languageCode: String?
    ) async -> Bool {
        // Built around the style's font family so the CJK plan resolves through
        // ITS cascade — serif must reach a Mincho face for Japanese lines, which
        // a sans-based plan would tag right past.
        let family = effectiveFontFamily(for: format)
        let renderer = SubtitleRenderer(defaultFontFamily: family)
        do {
            try await renderer.load(data, format: format, languageHint: languageCode)
        } catch {
            // A STALE failure must not tear down the newer pick's in-flight load —
            // `clear` cancels `fetchTask`, which by now may belong to the next
            // selection. Same guard the success path has.
            if Task.isCancelled { return false }
            Self.log.error("subtitle load failed (\(String(describing: format))): \(error)")
            return false
        }
        await renderer.setStyleOverride(effectiveStyleOverride(for: format))
        if Task.isCancelled { return false }
        installed = Installed(renderer: renderer,
                              info: SidecarSubtitleInfo(format: format, byteCount: data.count),
                              data: data, languageCode: languageCode, family: family)
        fetching = nil
        rendererGeneration &+= 1
        return true
    }

    /// The family the renderer plans fonts around — the style override's
    /// when the format takes it, else the renderer's own default.
    private func effectiveFontFamily(for format: SubtitleSourceFormat) -> String {
        effectiveStyleOverride(for: format)?.fontFamily ?? SubtitleRenderer.standardFontFamily
    }

    /// Nothing is drawn, and a fetch in flight is dropped.
    public func clear() {
        fetchTask?.cancel()
        fetchTask = nil
        fetching = nil
        installed = nil
        rendererGeneration &+= 1
    }

    /// The user's subtitle style, pushed by the overlay whenever preferences or the
    /// render geometry change. It reaches converted SRT/VTT only: those scripts are
    /// ours, synthesized field by field. An authored ASS/SSA track is someone else's
    /// typesetting and keeps all of it — the one thing we change, its typefaces
    /// (whose files we don't have), is already done at load inside the renderer.
    public func applyAppearance(converted: SubtitleStyleOverride?) {
        convertedAppearance = converted
        guard let installed else { return }
        let format = installed.info.format
        // A font-FAMILY change can't be pushed onto a loaded track: the CJK
        // font plan and \fn tags were baked at load against the previous
        // family. Rebuild the renderer from the kept payload instead — unless
        // another document's fetch is in flight: that install reads the family at
        // its own completion, and cancelling it here would strand the newer
        // pick on the old subtitle's payload.
        if fetching == nil, effectiveFontFamily(for: format) != installed.family {
            fetchTask?.cancel()
            fetchTask = Task { [weak self] in
                guard await self?.install(
                    data: installed.data, format: format,
                    languageCode: installed.languageCode
                ) == false, !Task.isCancelled else { return }
                self?.clear()
            }
            return
        }
        let effective = effectiveStyleOverride(for: format)
        let renderer = installed.renderer
        let previous = stylePushChain
        stylePushChain = Task {
            await previous?.value          // submission order → the LAST edit wins
            await renderer.setStyleOverride(effective)
        }
    }

    private func effectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        format.needsConversion ? convertedAppearance : nil
    }

    /// The session is over: nothing draws, and its cached bytes go with it.
    public func endSession() {
        clear()
        cache = [:]
    }
}

#if DEBUG
extension SubtitleDisplay {
    /// Awaits the in-flight fetch and load, so a test can read the renderer without racing it.
    public func awaitFetch() async {
        await fetchTask?.value
    }

    /// What one source format is handed, given the appearance the overlay last pushed. The
    /// converted-vs-authored rule lives in `effectiveStyleOverride` and nothing else observes it.
    public func debugEffectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        effectiveStyleOverride(for: format)
    }
}
#endif
