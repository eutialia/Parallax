import Foundation
import Observation
import ParallaxCore
import ParallaxPlayback
import ParallaxSubtitles

/// The client-drawn sidecar subtitle: the URLs a session offers, the fetch that turns one into
/// bytes (cached for the session), the libass renderer built from them, and the user's style
/// pushed onto it. Which track is selected is the player's call; this only draws it.
@Observable
@MainActor
final class SidecarSubtitles {
    /// The client-side renderer (libass, `ParallaxSubtitles`) for the active sidecar
    /// subtitle that `SubtitleOverlayView` draws: used by the transcode path AND by
    /// direct-play EXTERNAL subs (VLC can't shape sidecar text on iOS). Nil when no
    /// such subtitle is active — including direct-play EMBEDDED subs, which the engine
    /// renders itself. This is how we sidestep the in-manifest WebVTT drift
    /// (jellyfin/jellyfin#16647) while keeping authored ASS styling intact.
    private(set) var subtitleRenderer: SubtitleRenderer?
    /// Format + size the renderer was loaded with — debug panel and the style-override
    /// policy read it. Nil ⟺ `subtitleRenderer` is nil.
    private(set) var sidecarSubtitleInfo: SidecarSubtitleInfo?
    /// Monotonic token bumped on every renderer install/clear. The overlay keys its
    /// canvas pushes on this instead of object identity — a freed actor's address can
    /// be reused by its replacement, which would silently skip the new canvas push
    /// and leave the fresh renderer with a zero canvas (permanently blank subtitles).
    private(set) var subtitleRendererGeneration = 0

    /// Fetches sidecar subtitle bytes. Injectable so tests feed canned WebVTT
    /// without a network round-trip; production reads the authed sidecar URL over the
    /// app's transport.
    private let subtitleFetch: @Sendable (URL) async -> Data?

    private var subtitleFetchTask: Task<Void, Never>?
    /// The stream index the live `subtitleFetchTask` FETCH belongs to; nil once
    /// its install lands (or when the slot holds a same-track style rebuild).
    /// Guards the rebuild path: cancelling another track's in-flight fetch to
    /// rebuild from the INSTALLED payload would reinstall the old track under
    /// the new selection, and nothing would ever fetch the picked one.
    private(set) var sidecarFetchStreamIndex: Int?
    /// Last appearance pushed by the overlay (`applySubtitleAppearance`) — replayed
    /// onto every freshly loaded CONVERTED renderer so a track switch keeps the
    /// user's style. Its fontScale remaps the tuned per-device size onto the
    /// synthesized script's base, which only means anything for a script we wrote.
    private var convertedSubtitleAppearance: SubtitleStyleOverride?
    /// The current sidecar's raw payload, kept so a font-design change can
    /// REBUILD the renderer: the CJK `\fn` tags and font plan are baked at load
    /// against the style family, so a new family needs a fresh load, not a
    /// style push.
    private var sidecarPayload: (data: Data, format: SubtitleSourceFormat, languageCode: String?)?
    /// The family the current renderer was built around.
    private var sidecarRendererFamily: String?
    /// Identity of one fetched sidecar. The media source is part of it because a
    /// transcode reload re-resolves the SAME source (cache still valid) while an
    /// episode change resolves a different one (stream indices mean something else).
    private struct SidecarKey: Hashable {
        let mediaSourceID: String?
        let streamIndex: Int
    }
    /// Session cache of fetched sidecar bytes. The expensive part of a first pick
    /// is the server extracting an embedded stream through ffmpeg; re-selecting a
    /// track must never pay that twice. Dropped with the rest of the session state.
    private var sidecarCache: [SidecarKey: (data: Data, format: SubtitleSourceFormat)] = [:]
    private func sidecarKey(streamIndex: Int, mediaSourceID: String?) -> SidecarKey {
        SidecarKey(mediaSourceID: mediaSourceID, streamIndex: streamIndex)
    }

    /// Whether picking `streamIndex` costs a fetch. The loading affordance reads this so
    /// a re-pick of an already-fetched track doesn't flash a spinner for a parse.
    private func sidecarIsCached(streamIndex: Int, mediaSourceID: String?) -> Bool {
        sidecarCache[sidecarKey(streamIndex: streamIndex, mediaSourceID: mediaSourceID)] != nil
    }

    /// Serializes renderer style pushes: rapid preference edits must land on the actor
    /// in submission order or the renderer can finish on a stale style (the same
    /// discipline as `SubtitlePreferences.writeChain`).
    private var stylePushChain: Task<Void, Never>?

    /// Source-agnostic subtitle URL map: stream-index → sidecar URL. Jellyfin
    /// populates it from `resolved.subtitleStreamURLs` in `beginPlayback`; the
    /// SMB path populates it from the filename-matched sibling resolver before
    /// loading the engine. Both paths produce text-subtitle URLs (ASS/SSA/SRT/VTT)
    /// that `loadSidecarSubtitle` fetches into the client renderer.
    var subtitleURLs: [Int: URL] = [:]

    init(subtitleFetch: @escaping @Sendable (URL) async -> Data?) {
        self.subtitleFetch = subtitleFetch
    }

    isolated deinit {
        subtitleFetchTask?.cancel()
        stylePushChain?.cancel()
    }

    /// Show the loading affordance for a pick that is about to fetch: nothing for a track
    /// already in the session cache, whose pick is instant.
    func armFetchIndicator(streamIndex: Int, mediaSourceID: String?) {
        guard !sidecarIsCached(streamIndex: streamIndex, mediaSourceID: mediaSourceID) else { return }
        sidecarFetchStreamIndex = streamIndex
    }

    /// Fetches the sidecar subtitle for `streamIndex` and loads it into a fresh
    /// `SubtitleRenderer`. Cancels any in-flight fetch first so a slow/stale load
    /// can't land on screen after a newer pick. Format comes from the URL extension:
    /// the Jellyfin endpoint serves originals for formats we request verbatim
    /// (ass/ssa/srt keep their authored styling and positioning), and an SMB sibling
    /// is whatever the release shipped.
    func loadSidecarSubtitle(streamIndex: Int, languageCode: String?, mediaSourceID: String?) {
        subtitleFetchTask?.cancel()
        guard let url = subtitleURLs[streamIndex] else {
            clearSidecarSubtitle()
            return
        }
        let key = sidecarKey(streamIndex: streamIndex, mediaSourceID: mediaSourceID)
        if let cached = sidecarCache[key] {
            sidecarFetchStreamIndex = nil
            // Already fetched this session: no round trip, and — for an EMBEDDED
            // Jellyfin stream — no second ffmpeg extraction. Skip the loading state
            // too; the only cost left is the libass parse.
            subtitleFetchTask = Task { [weak self] in
                await self?.installSubtitleRenderer(
                    data: cached.data, format: cached.format, languageCode: languageCode
                )
            }
            return
        }
        // The first request is the only one the happy path pays: the verbatim
        // ass/ssa URL is what the renderer wants, and the VTT conversion below runs
        // ONLY when it comes back empty. Re-picking never re-pays either — the
        // bytes are cached above.
        sidecarFetchStreamIndex = streamIndex
        let fetch = subtitleFetch
        let requestedFormat = SubtitleSourceFormat(sidecarExtension: url.pathExtension)
        subtitleFetchTask = Task { [weak self] in
            var data = await fetch(url)
            var format = requestedFormat
            // A verbatim ass/ssa request can fail server-side (the endpoint only has
            // writers for some formats, and an embedded SSA track extracts as .ass) —
            // degrade to the server's VTT conversion: authored styling is lost, but
            // the track still shows instead of nothing.
            if data == nil, format == .ass || format == .ssa,
               let fallback = Self.vttFallbackURL(for: url) {
                data = await fetch(fallback)
                format = .vtt
            }
            if Task.isCancelled { return }
            guard let data else {
                // The CURRENT pick failed to fetch — leaving the previous track's
                // bitmaps on screen would lie about what's selected.
                self?.clearSidecarSubtitle()
                return
            }
            self?.sidecarCache[key] = (data, format)
            await self?.installSubtitleRenderer(data: data, format: format, languageCode: languageCode)
        }
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

    /// Builds + publishes the renderer for a fetched sidecar. A fresh renderer per
    /// load keeps track switches simple (no cross-track libass state); the overlay
    /// detects the swap via `subtitleRendererGeneration`. Undecodable data clears
    /// instead of throwing — same silent no-op the parse path always had, now logged.
    private func installSubtitleRenderer(
        data: Data,
        format: SubtitleSourceFormat,
        languageCode: String?
    ) async {
        // Built around the style's font family so the CJK plan resolves through
        // ITS cascade — serif must reach a Mincho face for Japanese lines, which
        // a sans-based plan would tag right past.
        let family = effectiveSidecarFontFamily(for: format)
        let renderer = SubtitleRenderer(defaultFontFamily: family)
        do {
            try await renderer.load(data, format: format, languageHint: languageCode)
        } catch {
            // A STALE failure must not tear down the newer pick's in-flight load —
            // `clearSidecarSubtitle` cancels `subtitleFetchTask`, which by now may
            // belong to the next selection. Same guard the success path has.
            if Task.isCancelled { return }
            Log.playback.error("sidecar subtitle load failed (\(String(describing: format))): \(error)")
            clearSidecarSubtitle()
            return
        }
        let info = SidecarSubtitleInfo(format: format, byteCount: data.count)
        await renderer.setStyleOverride(effectiveStyleOverride(for: format))
        if Task.isCancelled { return }
        subtitleRenderer = renderer
        sidecarSubtitleInfo = info
        sidecarPayload = (data, format, languageCode)
        sidecarRendererFamily = family
        sidecarFetchStreamIndex = nil
        subtitleRendererGeneration &+= 1
    }

    /// The family the sidecar renderer plans fonts around — the style override's
    /// when the format takes it, else the renderer's own default.
    private func effectiveSidecarFontFamily(for format: SubtitleSourceFormat) -> String {
        effectiveStyleOverride(for: format)?.fontFamily ?? SubtitleRenderer.standardFontFamily
    }

    func clearSidecarSubtitle() {
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        sidecarFetchStreamIndex = nil
        subtitleRenderer = nil
        sidecarSubtitleInfo = nil
        sidecarPayload = nil
        sidecarRendererFamily = nil
        subtitleRendererGeneration &+= 1
    }

    /// The user's subtitle style, pushed by the overlay whenever preferences or the
    /// render geometry change. It reaches converted SRT/VTT only: those scripts are
    /// ours, synthesized field by field. An authored ASS/SSA track is someone else's
    /// typesetting and keeps all of it — the one thing we change, its typefaces
    /// (whose files we don't have), is already done at load inside the renderer.
    func applySubtitleAppearance(converted: SubtitleStyleOverride?) {
        convertedSubtitleAppearance = converted
        guard let renderer = subtitleRenderer, let info = sidecarSubtitleInfo else { return }
        // A font-FAMILY change can't be pushed onto a loaded track: the CJK
        // font plan and \fn tags were baked at load against the previous
        // family. Rebuild the renderer from the kept payload instead — unless
        // another track's fetch is in flight: that install reads the family at
        // its own completion, and cancelling it here would strand the newer
        // pick on the old track's payload.
        if sidecarFetchStreamIndex == nil, let payload = sidecarPayload,
           effectiveSidecarFontFamily(for: info.format) != sidecarRendererFamily {
            subtitleFetchTask?.cancel()
            subtitleFetchTask = Task { [weak self] in
                await self?.installSubtitleRenderer(
                    data: payload.data, format: payload.format,
                    languageCode: payload.languageCode
                )
            }
            return
        }
        let effective = effectiveStyleOverride(for: info.format)
        let previous = stylePushChain
        stylePushChain = Task {
            await previous?.value          // submission order → the LAST edit wins
            await renderer.setStyleOverride(effective)
        }
    }

    private func effectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        format.needsConversion ? convertedSubtitleAppearance : nil
    }

    /// The session is over: nothing draws, and its URLs and cached bytes go with it.
    func endSession() {
        clearSidecarSubtitle()
        sidecarCache = [:]
        subtitleURLs = [:]
    }
}

#if DEBUG
extension SidecarSubtitles {
    /// Awaits the in-flight fetch and load, so a test can read the renderer without racing it.
    func awaitFetch() async {
        await subtitleFetchTask?.value
    }

    /// What one source format is handed, given the appearance the overlay last pushed. The
    /// converted-vs-authored rule lives in `effectiveStyleOverride` and nothing else observes it.
    func debugEffectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        effectiveStyleOverride(for: format)
    }
}
#endif
