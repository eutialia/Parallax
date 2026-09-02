import Testing
import Foundation
import CoreMedia
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

// FakePlaybackEngine, PlaybackEngineCapabilities.avKit, and FakeCapabilityProbe
// are imported from ParallaxPlaybackTestSupport.

struct NoopAudioSession: AudioSessionControlling {
    let routeChanges: AsyncStream<Void> = AsyncStream { _ in }
    func activate() async throws {}
    func deactivate() async {}
}

struct ThrowingAudioSession: AudioSessionControlling {
    let routeChanges: AsyncStream<Void> = AsyncStream { _ in }
    func activate() async throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: -50)
    }
    func deactivate() async {}
}

/// Records every Now Playing write the VM makes, so a test can assert on what the lock
/// screen would show without touching `MPNowPlayingInfoCenter` — a process-wide system
/// service whose contents outlive (and leak between) test cases.
@MainActor
final class SpyNowPlaying: NowPlayingUpdating {
    private(set) var configureCount = 0
    private(set) var updates: [(position: CMTime, duration: CMTime, isPlaying: Bool, title: String)] = []
    private(set) var clearCount = 0

    func configure(
        onSeek: @escaping @MainActor (CMTime) -> Void,
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void
    ) {
        configureCount += 1
    }

    func update(position: CMTime, duration: CMTime, isPlaying: Bool, title: String) {
        updates.append((position, duration, isPlaying, title))
    }

    func clear() { clearCount += 1 }
}

/// The engine factory's ledger: one distinct `FakePlaybackEngine` per call, tagged with the
/// id the view model ASKED for, kept in build order.
///
/// The alternative every player suite used to reach for — one fake handed back for every
/// factory call — silently masks engine rebuilds: the reload's reuse test compares the live
/// engine's id against the requested one, so a mis-tagged single instance reads as an engine
/// change and the test then asserts against one object replaying two sessions' calls. Here a
/// rebuild is simply a second entry.
@MainActor
final class EngineLedger {
    private(set) var engines: [FakePlaybackEngine] = []
    var count: Int { engines.count }
    var first: FakePlaybackEngine? { engines.first }

    /// The engine the view model is driving now — the newest one built. Traps on an empty
    /// ledger: every caller reads it after a `start()` that built one, so empty means a
    /// broken fixture rather than a case worth branching on.
    var live: FakePlaybackEngine { engines.last! }

    func make(_ id: PlaybackEngineID) -> FakePlaybackEngine {
        let engine = FakePlaybackEngine(id: id, capabilities: id == .avKit ? .avKit : .vlcKit)
        engines.append(engine)
        return engine
    }
}

/// The device profile every player suite builds its view model on: no HDR, stereo out.
func makeTestDeviceProfileBuilder() -> DeviceProfileBuilder {
    DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: .none, audioOutput: .stereo))
}

/// THE `PlayerViewModel` builder for every player suite: the test device profile, a
/// recording reporting stub, and one hook per injectable seam. Defaults mirror
/// `PlayerViewModel.init`'s own EXCEPT `subtitleFetch`, which returns empty data instead
/// of hitting the real `URLSession` — no test may reach the network. Module-scope so the
/// NowPlaying sub-suite and the segment suite share the identical builder.
@MainActor
func makePlayerVM(
    reporting: StubPlaybackReporting = StubPlaybackReporting(),
    resolve: @escaping PlayerViewModel.ResolveCall,
    engineFactory: @escaping @MainActor @Sendable (PlaybackEngineID, _ vlcLibraryOptions: [String]?) -> any PlaybackEngine,
    audioSession: any AudioSessionControlling = NoopAudioSession(),
    nowPlaying: any NowPlayingUpdating = NowPlayingController(),
    fetchDetail: @escaping @Sendable (ItemID) async throws -> ItemDetail = { _ in
        throw AppError.playback(.unsupportedFormat)
    },
    subtitleFetch: @escaping @Sendable (URL) async -> Data? = { _ in Data() },
    fetchSegments: @escaping @Sendable (ItemID) async -> [MediaSegment] = { _ in [] },
    fetchAdjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes = { _, _ in .none },
    keepaliveInterval: Duration = .seconds(30),
    fetchDelivery: @escaping @Sendable (String) async -> TranscodeDelivery? = { _ in nil },
    deliveryProbeSchedule: [Duration] = [.seconds(2), .seconds(5)],
    reloadResolveDeadline: Duration = .seconds(15),
    subtitleStyle: @escaping @MainActor () -> SubtitleStyle = { .standard },
    playerSurface: @escaping @MainActor () -> CGSize? = { nil },
    seekHoldNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    fetchArtwork: @escaping @Sendable (ItemDetail) async -> Data? = { _ in nil },
    rememberTrackSelection: @escaping @Sendable (TrackSelectionUpdate) async -> Void = { _ in }
) -> PlayerViewModel {
    PlayerViewModel(
        deviceProfileBuilder: makeTestDeviceProfileBuilder(),
        playbackInfo: reporting,
        resolve: resolve,
        engineFactory: engineFactory,
        audioSession: audioSession,
        nowPlaying: nowPlaying,
        fetchDetail: fetchDetail,
        subtitleFetch: subtitleFetch,
        rememberTrackSelection: rememberTrackSelection,
        fetchSegments: fetchSegments,
        fetchAdjacent: fetchAdjacent,
        keepaliveInterval: keepaliveInterval,
        fetchDelivery: fetchDelivery,
        deliveryProbeSchedule: deliveryProbeSchedule,
        reloadResolveDeadline: reloadResolveDeadline,
        subtitleStyle: subtitleStyle,
        playerSurface: playerSurface,
        seekHoldNow: seekHoldNow,
        fetchArtwork: fetchArtwork
    )
}

/// Single-engine convenience: the engine factory hands back the same fake for every id.
@MainActor
func makePlayerVM(
    reporting: StubPlaybackReporting = StubPlaybackReporting(),
    resolve: @escaping PlayerViewModel.ResolveCall,
    engine: FakePlaybackEngine,
    audioSession: any AudioSessionControlling = NoopAudioSession(),
    nowPlaying: any NowPlayingUpdating = NowPlayingController(),
    fetchDetail: @escaping @Sendable (ItemID) async throws -> ItemDetail = { _ in
        throw AppError.playback(.unsupportedFormat)
    },
    subtitleFetch: @escaping @Sendable (URL) async -> Data? = { _ in Data() },
    fetchSegments: @escaping @Sendable (ItemID) async -> [MediaSegment] = { _ in [] },
    fetchAdjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes = { _, _ in .none },
    keepaliveInterval: Duration = .seconds(30),
    fetchDelivery: @escaping @Sendable (String) async -> TranscodeDelivery? = { _ in nil },
    deliveryProbeSchedule: [Duration] = [.seconds(2), .seconds(5)],
    reloadResolveDeadline: Duration = .seconds(15),
    subtitleStyle: @escaping @MainActor () -> SubtitleStyle = { .standard },
    playerSurface: @escaping @MainActor () -> CGSize? = { nil },
    seekHoldNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    fetchArtwork: @escaping @Sendable (ItemDetail) async -> Data? = { _ in nil }
) -> PlayerViewModel {
    makePlayerVM(
        reporting: reporting,
        resolve: resolve,
        engineFactory: { _, _ in engine },
        audioSession: audioSession,
        nowPlaying: nowPlaying,
        fetchDetail: fetchDetail,
        subtitleFetch: subtitleFetch,
        fetchSegments: fetchSegments,
        fetchAdjacent: fetchAdjacent,
        keepaliveInterval: keepaliveInterval,
        fetchDelivery: fetchDelivery,
        deliveryProbeSchedule: deliveryProbeSchedule,
        reloadResolveDeadline: reloadResolveDeadline,
        subtitleStyle: subtitleStyle,
        playerSurface: playerSurface,
        seekHoldNow: seekHoldNow,
        fetchArtwork: fetchArtwork
    )
}

/// Canned-resolve convenience: resolve always returns `resolved`, optionally reporting
/// the requested item id to `capturedItem`.
@MainActor
func makePlayerVM(
    reporting: StubPlaybackReporting = StubPlaybackReporting(),
    engine: FakePlaybackEngine,
    resolved: ResolvedPlayback,
    audioSession: any AudioSessionControlling = NoopAudioSession(),
    nowPlaying: any NowPlayingUpdating = NowPlayingController(),
    capturedItem: @escaping @Sendable (ItemID) -> Void = { _ in }
) -> PlayerViewModel {
    makePlayerVM(
        reporting: reporting,
        resolve: { id, _, _, _ in
            capturedItem(id)
            return resolved
        },
        engine: engine,
        audioSession: audioSession,
        nowPlaying: nowPlaying
    )
}

enum PlayerFixtures {
    /// The one `MovieDetail` shape every non-episode player test starts from. `chapters` is
    /// what the `chapterFractions` memoization suite varies; `runtime` moves with it so the
    /// expected fractions stay exact.
    static func movieDetail(
        title: String = "Fixture Movie",
        positionTicks: Int64 = 0,
        runtime: Duration = .seconds(7200),
        chapters: [Chapter] = []
    ) -> ItemDetail {
        let movie = makeMovie(
            "movie-1", title: title, year: 2024, runtime: runtime, positionTicks: positionTicks
        )
        return .movie(MovieDetail(movie: movie, tagline: nil, studios: [], directors: [], people: [], chapters: chapters))
    }

    /// A movie detail carrying chapter markers — for the `chapterFractions` memoization.
    /// `runtime` and the chapter starts are caller-chosen so the expected fractions are exact.
    static func movieDetailWithChapters(startsSeconds: [Double], runtime: Duration) -> ItemDetail {
        movieDetail(
            title: "Chaptered Movie",
            runtime: runtime,
            chapters: startsSeconds.enumerated().map { index, seconds in
                Chapter(index: index, name: "Chapter \(index + 1)", start: .seconds(seconds))
            }
        )
    }

    /// An episode `ItemDetail` (carries `seriesID`, so adjacency wiring applies).
    static func episodeDetail(
        id: String,
        seriesID: String = "series-1",
        name: String = "Episode",
        season: Int = 1,
        number: Int = 1,
        positionTicks: Int64 = 0,
        runtime: Duration = .seconds(1800)
    ) -> ItemDetail {
        let episode = Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: "season-\(season)"),
            name: name,
            seriesName: nil,
            indexNumber: number,
            parentIndexNumber: season,
            overview: nil,
            runtime: runtime,
            primaryTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: positionTicks, playCount: 0, isFavorite: false)
        )
        return .episode(EpisodeDetail(episode: episode, people: []))
    }

    /// A plain `Episode` — an adjacency neighbor (prev/next), not a full detail.
    static func episode(id: String, seriesID: String = "series-1", season: Int = 1, number: Int = 1) -> Episode {
        Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: "season-\(season)"),
            name: "S\(season)E\(number)",
            seriesName: nil,
            indexNumber: number,
            parentIndexNumber: season,
            overview: nil,
            runtime: .seconds(1800),
            primaryTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
    }

    /// The plain AVKit-playable direct-play resolve (mp4 / h264 / aac). Both public
    /// entry points below are this one literal with a different id and runtime.
    private static func resolvedDirectPlay(
        itemID: String,
        mediaSourceID: String,
        playSessionID: String,
        runtimeSeconds: Double
    ) -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: itemID,
            url: URL(string: "https://jf.example.com/Videos/\(itemID)/stream.m3u8?api_key=abc")!,
            method: .directPlay,
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            mediaSourceID: mediaSourceID,
            playSessionID: playSessionID,
            runtime: CMTime(seconds: runtimeSeconds, preferredTimescale: 600),
            startTime: nil
        )
    }

    /// A direct-play `ResolvedPlayback` for an arbitrary episode id — used by the
    /// succession tests whose resolve closure keys on the requested item.
    static func resolvedEpisode(id: String) -> ResolvedPlayback {
        resolvedDirectPlay(itemID: id, mediaSourceID: "ms-\(id)", playSessionID: "ps-\(id)", runtimeSeconds: 1800)
    }

    static func resolved() -> ResolvedPlayback {
        resolvedDirectPlay(itemID: "movie-1", mediaSourceID: "ms-1", playSessionID: "ps-1", runtimeSeconds: 7200)
    }

    /// A server-transcoded MKV (bug #2): the *source* is MKV / AV1 / DTS — none
    /// of which AVKit can direct-play — but the server delivers an HLS transcode
    /// stream AVKit *can* play. The engine selector must gate on the delivered
    /// stream (HLS), not the source container.
    static func resolvedTranscodedMKV() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/videos/movie-1/master.m3u8?api_key=abc")!,
            method: .transcode,
            container: .mkv,
            videoCodec: .av1,
            audioCodec: .dts,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil
        )
    }

    /// A transcoded MKV with a full multi-track source: 3 audio + 2 subtitle
    /// streams. The HLS transcode only carries the default rendition, so the
    /// menus must come from `mediaStreams` and switching re-resolves.
    /// `burnInDeliveryMethod` is what the server says it will do with the image
    /// subtitle at index 7. "Encode" is the healthy answer — it paints the picture
    /// into the video. Anything else (nil included) is a server that accepted the
    /// request and quietly declined to burn anything in, which is invisible on
    /// screen and is exactly what the post-switch check exists to catch.
    static func resolvedMultiTrackTranscode(
        startTime: CMTime? = nil,
        defaultSubtitleStreamIndex: Int? = 1,
        burnInDeliveryMethod: String? = "Encode",
        chineseSidecarURL: URL = URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/1/Stream.vtt?api_key=abc&copyTimestamps=true")!
    ) -> ResolvedPlayback {
        func audio(_ i: Int, _ title: String) -> MediaStreamInfo {
            MediaStreamInfo(index: i, kind: .audio, displayTitle: title, language: "jpn",
                            codec: "truehd", channels: 8, isExternal: false, isForced: false, isDefault: i == 3)
        }
        func sub(
            _ i: Int, _ title: String, _ lang: String,
            _ codec: String = "subrip",
            deliveryMethod: String? = nil
        ) -> MediaStreamInfo {
            MediaStreamInfo(index: i, kind: .subtitle, displayTitle: title, language: lang,
                            codec: codec, channels: nil, isExternal: true, isForced: false, isDefault: i == 1,
                            subtitleDeliveryMethod: deliveryMethod)
        }
        return ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/videos/movie-1/master.m3u8?api_key=abc")!,
            method: .transcode,
            container: .mkv,
            videoCodec: .hevc,
            audioCodec: .trueHD,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: startTime,
            mediaStreams: [
                audio(3, "Surround 7.1 - Japanese - Default"),
                audio(4, "Surround 5.1 - Japanese"),
                audio(5, "Stereo - Japanese"),
                sub(1, "Chinese", "zho"),                       // text (SubRip)
                // image — opt-in burn-in menu entry, no sidecar URL below
                sub(7, "English - PGSSUB", "eng", "pgssub", deliveryMethod: burnInDeliveryMethod),
            ],
            defaultAudioStreamIndex: 3,
            defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
            subtitleStreamURLs: [
                1: chineseSidecarURL
            ]
        )
    }

    /// VC-1 MKV direct-play — routes to .vlcKit because .vc1 is not in
    /// EngineSelector's avKitVideoCodecs set. The audio codec is the only axis the two
    /// callers differ on (a DTS track vs an AVKit-playable AAC one).
    /// `itemID` is a seam, not decoration: `streamSelection` only carries the standing
    /// stream indices when the resolve belongs to the item being played, so a reload the
    /// server answers with a direct-play stream for the SAME item has to say so.
    static func resolvedVC1MKV(audioCodec: AudioCodec = .dts, itemID: String = "movie-2") -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: itemID,
            url: URL(string: "https://jf.example.com/Videos/movie-2/stream.mkv?api_key=abc")!,
            method: .directPlay,
            container: .mkv,
            videoCodec: .vc1,
            audioCodec: audioCodec,
            mediaSourceID: "ms-2",
            playSessionID: "ps-2",
            runtime: CMTime(seconds: 5400, preferredTimescale: 600),
            startTime: nil
        )
    }

    /// A direct-play MKV (VC-1 → .vlcKit) whose server-preferred subtitle is an
    /// EXTERNAL sidecar. Drives the double-subtitle fix: activating the external sub
    /// must deselect the engine's own track, because VLC auto-picks an embedded default
    /// (and discovers more text tracks as the demux runs) that would otherwise render
    /// THROUGH the client overlay.
    static func resolvedDirectPlayExternalSub() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/Videos/movie-1/stream.mkv?api_key=abc")!,
            method: .directPlay,
            container: .mkv,
            videoCodec: .vc1,       // routes to .vlcKit, like the reported case
            audioCodec: .aac,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil,
            mediaStreams: [
                MediaStreamInfo(index: 2, kind: .subtitle, displayTitle: "English", language: "eng",
                                codec: "subrip", channels: nil, isExternal: true, isForced: false, isDefault: true)
            ],
            defaultAudioStreamIndex: nil,
            defaultSubtitleStreamIndex: 2,
            subtitleStreamURLs: [
                2: URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/2/Stream.vtt?api_key=abc&copyTimestamps=true")!
            ]
        )
    }

    /// A direct-play MKV whose subtitles are all EMBEDDED: one text stream (index 2,
    /// with a sidecar URL, because Jellyfin builds one for every text stream) and one
    /// image stream (index 3, no URL — the server can only burn those in). The shape
    /// the "embedded text renders client-side on direct play" contract is about.
    static func resolvedDirectPlayEmbeddedSubs(
        textURL: URL = URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/2/Stream.srt?api_key=abc")!,
        secondTextURL: URL = URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/4/Stream.srt?api_key=abc")!
    ) -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/Videos/movie-1/stream.mkv?api_key=abc")!,
            method: .directPlay,
            container: .mkv,
            videoCodec: .vc1,      // routes to .vlcKit, like a real fansub MKV
            audioCodec: .aac,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil,
            mediaStreams: [
                MediaStreamInfo(index: 2, kind: .subtitle, displayTitle: "English", language: "eng",
                                codec: "subrip", channels: nil, isExternal: false,
                                isForced: false, isDefault: true),
                MediaStreamInfo(index: 3, kind: .subtitle, displayTitle: "English - PGSSUB", language: "eng",
                                codec: "pgssub", channels: nil, isExternal: false,
                                isForced: false, isDefault: false,
                                subtitleDeliveryMethod: "Encode"),
                MediaStreamInfo(index: 4, kind: .subtitle, displayTitle: "French", language: "fra",
                                codec: "subrip", channels: nil, isExternal: false,
                                isForced: false, isDefault: false),
            ],
            defaultAudioStreamIndex: nil,
            // No server default: the tests below drive the picks explicitly, and an
            // auto-armed default would fetch once before they start.
            defaultSubtitleStreamIndex: nil,
            subtitleStreamURLs: [2: textURL, 4: secondTextURL]
        )
    }

    /// A direct-play MKV with an explicit subtitle mix, for the "who renders which
    /// stream" contract. Every TEXT stream gets a sidecar URL (Jellyfin builds one for
    /// each) and every IMAGE stream gets none — which is exactly the coverage
    /// `ResolvedPlayback.clientRendersAllSubtitles` reads. Languages are per-stream so a
    /// case can make the engine↔stream join unambiguous (or deliberately not).
    ///
    /// - Parameters:
    ///   - text: stream index → language, for the text streams.
    ///   - image: stream index → language, for the PGS/VobSub streams.
    static func resolvedDirectPlaySubtitleMix(
        text: [Int: String] = [:],
        image: [Int: String] = [:],
        defaultSubtitleStreamIndex: Int? = nil
    ) -> ResolvedPlayback {
        func stream(_ index: Int, _ language: String, image isImage: Bool) -> MediaStreamInfo {
            MediaStreamInfo(
                index: index, kind: .subtitle,
                displayTitle: isImage ? "Image \(index)" : "Text \(index)",
                language: language, codec: isImage ? "pgssub" : "subrip",
                channels: nil, isExternal: false, isForced: false, isDefault: false,
                subtitleDeliveryMethod: isImage ? "Encode" : nil
            )
        }
        let streams = (text.map { (index: $0.key, language: $0.value, image: false) }
            + image.map { (index: $0.key, language: $0.value, image: true) })
            .sorted { $0.index < $1.index }
        return ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/Videos/movie-1/stream.mkv?api_key=abc")!,
            method: .directPlay,
            container: .mkv,
            videoCodec: .vc1,      // routes to .vlcKit
            audioCodec: .aac,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil,
            mediaStreams: streams.map { stream($0.index, $0.language, image: $0.image) },
            defaultAudioStreamIndex: nil,
            // No server default unless a case asks for one: the rest drive the picks
            // explicitly, and an auto-armed default would move first.
            defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
            subtitleStreamURLs: Dictionary(uniqueKeysWithValues: text.keys.map {
                ($0, URL(string: "https://jf.example.com/Subtitles/\($0)/Stream.srt?api_key=abc")!)
            })
        )
    }

    /// What a direct-play ENGINE reports for `resolved`: one track per subtitle stream,
    /// under the engine's own id namespace and its raw container naming. This is the
    /// inventory the menu builder has to join back to the server's list.
    static func engineSubtitleInventory(for resolved: ResolvedPlayback) -> TrackInventory {
        TrackInventory(
            audio: [],
            subtitles: resolved.mediaStreams
                .filter { $0.kind == .subtitle }
                .map {
                    SubtitleTrack(id: .vlc("vlc-s\($0.index)"),
                                  displayName: $0.isImageSubtitle ? "PGS" : "SubRip",
                                  languageCode: $0.language,
                                  isForced: false)
                }
        )
    }

    /// A VP9/WebM/Opus direct-play item — container and codec both outside the AVKit
    /// whitelist, so EngineSelector routes it to .vlcKit.
    static func resolvedVP9WebM() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-2",
            url: URL(string: "https://jf.example.com/Videos/movie-2/stream.webm?api_key=abc")!,
            method: .directPlay,
            container: .webm,
            videoCodec: .vp9,
            audioCodec: .opus,
            mediaSourceID: "ms-2",
            playSessionID: "ps-2",
            runtime: CMTime(seconds: 3600, preferredTimescale: 600),
            startTime: nil
        )
    }
}

/// The transcode menu row carrying a Jellyfin stream index. Every reload fixture builds its
/// menus from the same stream indices, so naming a track by index is how the suites say
/// "audio 4" without re-deriving the row each time.
@MainActor
func audioTrack(_ vm: PlayerViewModel, _ index: Int) throws -> AudioTrack {
    try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(index) })
}

/// `audioTrack`'s subtitle half. Index 1 is the Chinese sidecar, 7 the English burn-in.
@MainActor
func subtitleTrack(_ vm: PlayerViewModel, _ index: Int) throws -> SubtitleTrack {
    try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(index) })
}

/// Arm `gate`, run `action` (the seek or pick that starts a reload) on its own task, and stand
/// there until the reload is really in flight — the opening move of every case that acts
/// DURING a reload. Returns the task, so the caller awaits the whole drain after `gate.open()`.
@MainActor
func startReload(
    _ gate: ResolveGate,
    on vm: PlayerViewModel,
    _ what: Comment = "the action never reached the reload",
    sourceLocation: SourceLocation = #_sourceLocation,
    action: @escaping @MainActor @Sendable () async -> Void
) async throws -> Task<Void, Never> {
    await gate.arm()
    let task = Task { @MainActor in await action() }
    try await requireEventually({ vm.isMidSessionReload }, what, sourceLocation: sourceLocation)
    return task
}

/// Parks an injected `resolve` until a test lets it through, so the windows the view model
/// only opens DURING a re-resolve — `isMidSessionReload`, the frozen surface, the `.loading`
/// scrim — become states a test can stand inside and probe rather than races to win.
///
/// Armed explicitly (not on construction) because the same closure serves the fixture's own
/// `start()`: a gate that blocked from the first call would deadlock the setup it is meant to
/// follow.
actor ResolveGate {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func wait() async {
        guard armed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Disarms and releases everything parked.
    func open() {
        armed = false
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }
}

/// THE mid-session-reload fixture: a playing transcode VM parked at `seconds`, with a buffer
/// that ends 60s later — so every seek past it takes the slow `reloadTranscode` road, which is
/// the window the reload suites stand inside.
///
/// Engines come from an `EngineLedger`, so each one carries the id the view model asked for and
/// a reload that RE-BUILDS shows up as a second entry — the caller's `engine` local then still
/// points at the outgoing engine, which is a legible failure instead of one instance replaying
/// two sessions' calls.
///
/// `sidecarUp` (default) leaves a client-rendered text sub selected: it is the one consumer
/// that reads the player clock ABSOLUTELY, so with it up an out-of-buffer seek re-anchors
/// instead of drifting in-stream. Turn it off for the cases that want the dirty-timeline road,
/// or that must prove a sidecar URL is read from the session the reload opens.
@MainActor
func makeReanchorVM(
    at seconds: Double,
    reporting: StubPlaybackReporting = StubPlaybackReporting(),
    seekHoldNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    nowPlaying: any NowPlayingUpdating = NowPlayingController(),
    subtitleFetch: @escaping @Sendable (URL) async -> Data? = { _ in Data() },
    rememberTrackSelection: @escaping @Sendable (TrackSelectionUpdate) async -> Void = { _ in },
    sidecarUp: Bool = true,
    resolve: @escaping PlayerViewModel.ResolveCall = { _, _, _, _ in
        PlayerFixtures.resolvedMultiTrackTranscode()
    }
) async throws -> (vm: PlayerViewModel, engines: EngineLedger) {
    let engines = EngineLedger()
    let vm = makePlayerVM(reporting: reporting, resolve: resolve,
                          engineFactory: { id, _ in engines.make(id) },
                          nowPlaying: nowPlaying,
                          subtitleFetch: subtitleFetch,
                          seekHoldNow: seekHoldNow,
                          rememberTrackSelection: rememberTrackSelection)
    await vm.start(item: PlayerFixtures.movieDetail())
    let engine = engines.live
    engine.push(.playing(seconds))
    try await engine.settle()
    // A precondition, not an assertion: every test on this fixture reads "the bar moved OFF A",
    // which proves nothing if the fixture never parked at A. Stop here instead.
    try #require(CMTimeGetSeconds(vm.currentPosition) == seconds)

    if sidecarUp {
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
    }
    engine.bufferedRange = 0...(seconds + 60)
    return (vm, engines)
}
