import Foundation
import CoreMedia
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("PlaybackInfoService — resolve")
struct PlaybackInfoServiceResolveTests {
    private func caps() -> DeviceCapabilities { JellyfinFixtures.caps() }

    private func directPlaySource() -> MediaSourceInfo {
        var source = MediaSourceInfo()
        source.id = "ms-1"
        source.container = "mp4"
        source.runTimeTicks = 1_000_000_000  // 100s
        source.isSupportsDirectStream = true
        source.transcodingURL = nil
        var video = MediaStream()
        video.type = .video
        video.codec = "h264"
        var audio = MediaStream()
        audio.type = .audio
        audio.codec = "aac"
        source.mediaStreams = [video, audio]
        return source
    }

    private func transcodeSource() -> MediaSourceInfo {
        var source = MediaSourceInfo()
        source.id = "ms-2"
        source.container = "mkv"
        source.runTimeTicks = 1_000_000_000
        source.transcodingURL = "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1"
        source.defaultAudioStreamIndex = 3
        source.defaultSubtitleStreamIndex = 1
        var video = MediaStream()
        video.type = .video
        video.index = 0
        video.codec = "hevc"
        video.profile = "Main 10"
        video.bitDepth = 10
        video.width = 3840
        video.height = 2160
        video.videoRange = .hdr
        video.videoRangeType = .hdr10
        video.colorSpace = "bt2020nc"
        video.bitRate = 18_200_000
        video.realFrameRate = 23.976
        var audio = MediaStream()
        audio.type = .audio
        audio.index = 3
        audio.codec = "truehd"
        audio.channels = 8
        audio.sampleRate = 48_000
        audio.bitRate = 4_500_000
        audio.displayTitle = "English - TrueHD 7.1"
        audio.language = "eng"
        audio.isDefault = true
        var subtitle = MediaStream()
        subtitle.type = .subtitle
        subtitle.index = 1
        subtitle.codec = "subrip"
        subtitle.displayTitle = "Chinese"
        subtitle.language = "zho"
        subtitle.deliveryMethod = .hls
        source.mediaStreams = [video, audio, subtitle]
        return source
    }

    /// A transcode whose URL carries `TranscodeReasons` (the server tells us *why*
    /// it's transcoding) — parsed onto `ResolvedPlayback.transcodeReasons`.
    private func transcodeSourceWithReasons() -> MediaSourceInfo {
        var source = transcodeSource()
        source.transcodingURL =
            "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1&TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported"
        return source
    }

    private func makeService(source: MediaSourceInfo) -> (PlaybackInfoService, FakeJellyfinPlaybackClient) {
        let fake = FakeJellyfinPlaybackClient()
        var response = PlaybackInfoResponse()
        response.mediaSources = [source]
        response.playSessionID = "ps-1"
        fake.playbackInfoResult = .success(response)
        return (PlaybackInfoService(client: fake), fake)
    }

    @Test("Non-transcode source resolves to .directPlay with a static (range-seekable) stream URL")
    func directBranch() async throws {
        let (service, fake) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        // AVPlayer requires HTTP byte-range support for progressive playback,
        // which Jellyfin's raw-file (static=true) direct-play endpoint provides
        // but its on-the-fly remux (static=false) does not — the remux answers
        // 200/chunked, which AVFoundation rejects (-12939 / -11850). A
        // non-transcode source is AVKit-native per our device profile, so we
        // direct-play the raw, seekable file.
        #expect(resolved.method == .directPlay)
        #expect(fake.streamURLRequests.first?.isStatic == true)
        #expect(resolved.mediaSourceID == "ms-1")
        #expect(resolved.playSessionID == "ps-1")
        #expect(resolved.container == .mp4)
        #expect(resolved.videoCodec == .h264)
        #expect(resolved.audioCodec == .aac)
        // Wiring, not URL shape: the resolved URL IS what the stream-URL builder returned. The
        // api_key/`/Videos/{id}/stream.{container}` shape is proven where the real builder runs
        // (`DefaultJellyfinPlaybackClientTests`); asserting it here would only re-read a canned
        // string this fake wrote.
        #expect(resolved.url == fake.streamURLValue)
        #expect(fake.streamURLRequests.first?.mediaSourceID == "ms-1")
        #expect(fake.streamURLRequests.first?.container == "mp4")
        #expect(fake.transcodePaths.isEmpty)
    }

    @Test("Server transcodingURL forces .transcode regardless of profile")
    func transcodeBranch() async throws {
        let (service, fake) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.method == .transcode)
        // It resolved the SERVER-provided transcodingURL verbatim, and returned exactly what the
        // transcode-URL builder handed back — no stream URL was built at all.
        #expect(fake.transcodePaths == ["/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1"])
        #expect(resolved.url == fake.transcodeURLValue)
        #expect(fake.streamURLRequests.isEmpty)
    }

    /// An explicit pick forces the server to build the transcode around that source track; nil
    /// hands the choice back to the server's own language preferences.
    @Test(
        "The selection reaches the PlaybackInfo request exactly as given",
        arguments: [
            StreamSelection(mediaSourceID: "ms-2", audioStreamIndex: 4, subtitleStreamIndex: 7),
            StreamSelection(mediaSourceID: "ms-2", audioStreamIndex: nil, subtitleStreamIndex: 7, burnsInSubtitle: true),
            nil,
        ] as [StreamSelection?]
    )
    func streamSelectionForwarded(selection: StreamSelection?) async throws {
        let (service, fake) = makeService(source: transcodeSource())
        _ = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil,
            selection: selection
        )
        #expect(fake.playbackInfoCalls.first?.selection == selection)
    }

    @Test("Source media streams + default indices are mapped to ResolvedPlayback")
    func mediaStreamsMapped() async throws {
        let (service, _) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.mediaStreams.count == 3)
        #expect(resolved.defaultAudioStreamIndex == 3)
        #expect(resolved.defaultSubtitleStreamIndex == 1)

        let audio = resolved.mediaStreams.first { $0.kind == .audio }
        #expect(audio?.index == 3)
        #expect(audio?.displayTitle == "English - TrueHD 7.1")
        #expect(audio?.language == "eng")
        #expect(audio?.channels == 8)
        #expect(audio?.isDefault == true)
        #expect(audio?.sampleRate == 48_000)
        #expect(audio?.bitRate == 4_500_000)

        let subtitle = resolved.mediaStreams.first { $0.kind == .subtitle }
        #expect(subtitle?.index == 1)
        #expect(subtitle?.displayTitle == "Chinese")
        #expect(subtitle?.subtitleDeliveryMethod == "Hls")
    }

    /// Image subs (PGS/VobSub) are burned in server-side, so they have no sidecar to fetch — but
    /// they must still stay in `mediaStreams` so the transcode menu can offer them. Text subs are
    /// requested in their ORIGINAL format when the client renderer ingests it natively (the
    /// server's VTT conversion strips authored ASS styling and SRT placement tags); everything
    /// else falls back to the server's VTT conversion.
    @Test("Sidecar URLs are requested for text subtitles only, in their renderable original format")
    func subtitleSidecarURLsBuilt() async throws {
        var source = transcodeSource()          // text sub: index 1, subrip
        var pgs = MediaStream()                  // image sub: index 2, pgssub
        pgs.type = .subtitle
        pgs.index = 2
        pgs.codec = "pgssub"
        var ass = MediaStream()                  // authored styling: fetched verbatim
        ass.type = .subtitle
        ass.index = 3
        ass.codec = "ass"
        var movText = MediaStream()              // no native ingest: server converts to vtt
        movText.type = .subtitle
        movText.index = 4
        movText.codec = "mov_text"
        source.mediaStreams?.append(contentsOf: [pgs, ass, movText])
        let (service, fake) = makeService(source: source)

        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )

        #expect(resolved.subtitleStreamURLs.count == 3)
        #expect(resolved.subtitleStreamURLs[2] == nil, "an image sub has no sidecar to fetch")
        #expect(resolved.mediaStreams.contains { $0.index == 2 }, "but it stays selectable for burn-in")
        // One request per text stream, each in its wire format — the URL's own shape is pinned
        // in `DefaultJellyfinPlaybackClientTests`, not against a string this fake made up.
        #expect(fake.subtitleStreamURLRequests.map(\.streamIndex) == [1, 3, 4])
        #expect(fake.subtitleStreamURLRequests.map(\.format) == ["srt", "ass", "vtt"])
        #expect(fake.subtitleStreamURLRequests.first?.mediaSourceID == "ms-2")
        #expect(resolved.subtitleStreamURLs[1] == fake.subtitleURLForIndex(1))
    }

    @Test("Video stream's HDR / resolution / bit-depth debug fields are mapped")
    func videoDebugFieldsMapped() async throws {
        let (service, _) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        let video = resolved.mediaStreams.first { $0.kind == .video }
        #expect(video?.profile == "Main 10")
        #expect(video?.bitDepth == 10)
        #expect(video?.width == 3840)
        #expect(video?.height == 2160)
        #expect(video?.videoRange == "HDR")
        #expect(video?.videoRangeType == "HDR10")
        #expect(video?.colorSpace == "bt2020nc")
        #expect(video?.bitRate == 18_200_000)
        #expect(video?.frameRate == 23.976)
    }

    /// Reasons are read out of the SERVER's transcodingURL query, so direct play (no such URL)
    /// necessarily has none.
    @Test(
        "TranscodeReasons come from the transcoding URL, in order",
        arguments: [
            (ResolveSource.transcodeWithReasons, ["ContainerNotSupported", "AudioCodecNotSupported"]),
            (.transcode, []),
            (.directPlay, []),
        ]
    )
    func transcodeReasonsParsed(source: ResolveSource, expected: [String]) async throws {
        let (service, _) = makeService(source: mediaSource(for: source))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.transcodeReasons == expected)
    }

    enum ResolveSource: Sendable { case directPlay, transcode, transcodeWithReasons }

    private func mediaSource(for kind: ResolveSource) -> MediaSourceInfo {
        switch kind {
        case .directPlay: directPlaySource()
        case .transcode: transcodeSource()
        case .transcodeWithReasons: transcodeSourceWithReasons()
        }
    }

    @Test("startTime is converted to ticks (seconds * 10_000_000) for the POST and echoed back")
    func tickConversion() async throws {
        let (service, fake) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: CMTime(seconds: 12, preferredTimescale: 600)
        )
        #expect(fake.playbackInfoCalls.first?.startTimeTicks == 120_000_000)
        #expect(resolved.startTime == CMTime(seconds: 12, preferredTimescale: 600))
    }

    @Test("Runtime ticks from the chosen source map to ResolvedPlayback.runtime")
    func runtimeMapped() async throws {
        let (service, _) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.runtime == CMTime(seconds: 100, preferredTimescale: 10_000_000))
    }

    @Test("isHearingImpaired maps through mediaStreamInfos")
    func hearingImpairedMapped() async throws {
        var source = transcodeSource()
        var sdhSub = MediaStream()
        sdhSub.type = .subtitle
        sdhSub.index = 5
        sdhSub.codec = "subrip"
        sdhSub.displayTitle = "English SDH"
        sdhSub.isHearingImpaired = true
        var normalSub = MediaStream()
        normalSub.type = .subtitle
        normalSub.index = 6
        normalSub.codec = "subrip"
        normalSub.displayTitle = "English"
        normalSub.isHearingImpaired = false
        source.mediaStreams?.append(contentsOf: [sdhSub, normalSub])
        let (service, _) = makeService(source: source)
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        let sdh = try #require(resolved.mediaStreams.first { $0.index == 5 })
        #expect(sdh.isHearingImpaired == true)
        let normal = try #require(resolved.mediaStreams.first { $0.index == 6 })
        #expect(normal.isHearingImpaired == false)
    }

    /// A source whose stream URL can't be built is unplayable — better a named failure than an
    /// engine handed a nil URL.
    @Test("An unbuildable stream URL throws instead of resolving something unplayable")
    func unbuildableStreamURLThrows() async {
        let (service, fake) = makeService(source: directPlaySource())
        fake.streamURLValue = nil
        await #expect(throws: AppError.self) {
            _ = try await service.resolve(
                item: ItemID(rawValue: "item-1"),
                capabilities: caps(),
                startTime: nil
            )
        }
    }

    /// An index is a stream's only stable identity AND the value the server selects by, so an
    /// index-less stream can never be chosen — it's dropped rather than shown in the track menu.
    @Test("Streams without an index are dropped, and unknown types fold to .other")
    func streamsWithoutIndexAreDropped() async throws {
        var source = directPlaySource()
        var indexless = MediaStream()
        indexless.type = .audio
        indexless.codec = "aac"
        var embeddedImage = MediaStream()
        embeddedImage.type = .embeddedImage
        embeddedImage.index = 9
        source.mediaStreams = [indexless, embeddedImage]
        let (service, _) = makeService(source: source)

        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )

        #expect(resolved.mediaStreams.map(\.index) == [9])
        #expect(resolved.mediaStreams.first?.kind == .other)
    }

    /// A missing item is a 404 from the client; the service maps it into the domain error type
    /// rather than letting a raw SDK error reach the player.
    @Test("A failed PlaybackInfo request maps to AppError")
    func playbackInfoFailureMaps() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.playbackInfoResult = .failure(URLError(.timedOut))
        let service = PlaybackInfoService(client: fake)
        await #expect(throws: AppError.self) {
            _ = try await service.resolve(
                item: ItemID(rawValue: "item-1"),
                capabilities: caps(),
                startTime: nil
            )
        }
    }

    // MARK: - Client-side default-subtitle fallback

    /// The server only auto-selects a subtitle when its own preference matching
    /// hits (dashless alpha-3 vs exact culture row — the two never bridge), so a
    /// `zh-Hans` external sub stays unselected under a stored "zho". These cover
    /// the client-side rescue.
    private func fallbackSource(
        defaultSubtitleIndex: Int? = nil,
        subtitles: [(index: Int, language: String?, codec: String, forced: Bool)]
    ) -> MediaSourceInfo {
        var source = directPlaySource()
        source.defaultSubtitleStreamIndex = defaultSubtitleIndex
        var video = MediaStream()
        video.type = .video
        video.index = 0
        video.codec = "h264"
        source.mediaStreams = [video] + subtitles.map { spec in
            var stream = MediaStream()
            stream.type = .subtitle
            stream.index = spec.index
            stream.language = spec.language
            stream.codec = spec.codec
            stream.isForced = spec.forced
            return stream
        }
        return source
    }

    private func userConfiguration(
        preference: String?,
        mode: SubtitlePlaybackMode?
    ) -> UserConfiguration {
        UserConfiguration(subtitleLanguagePreference: preference, subtitleMode: mode)
    }

    @Test("A nil server default is filled from the user's subtitle preference across tag dialects", arguments: [
        // Stored alpha-3 bridges to script-tagged streams; first in stream order wins.
        ("zho", 2),
        // A script-carrying preference outranks stream order.
        ("zh-Hans", 3),
        ("zh-Hant", 2),
        // A preference nothing matches leaves the choice to the player.
        ("jpn", nil),
    ] as [(String, Int?)])
    func fallbackSubtitlePicked(preference: String, expected: Int?) async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: [
            (2, "zh-hant", "subrip", false),
            (3, "zh-hans", "subrip", false),
        ]))
        fake.userConfigurationResult = .success(userConfiguration(preference: preference, mode: .always))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultSubtitleStreamIndex == expected)
    }

    /// Only `Always` means "show subtitles by default"; every other mode is the
    /// user asking us not to.
    @Test("Any subtitle mode other than Always leaves the default nil", arguments: [
        SubtitlePlaybackMode.none, .default, .onlyForced, .smart, nil,
    ] as [SubtitlePlaybackMode?])
    func fallbackHonorsSubtitleMode(mode: SubtitlePlaybackMode?) async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: [(2, "zho", "subrip", false)]))
        fake.userConfigurationResult = .success(userConfiguration(preference: "zho", mode: mode))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultSubtitleStreamIndex == nil)
    }

    /// Forced subs are a burned-in-signs substitute, not a track someone asked
    /// for; image subs would cost a full re-encode to show.
    @Test("Forced-only and image-only candidates are never auto-selected", arguments: [
        [(2, "zho", "subrip", true)],
        [(2, "zho", "pgssub", false)],
    ] as [[(index: Int, language: String?, codec: String, forced: Bool)]])
    func fallbackSkipsForcedAndImageSubs(
        subtitles: [(index: Int, language: String?, codec: String, forced: Bool)]
    ) async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: subtitles))
        fake.userConfigurationResult = .success(userConfiguration(preference: "zho", mode: .always))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultSubtitleStreamIndex == nil)
    }

    @Test("An empty preference or a failed configuration fetch leaves the default nil", arguments: [false, true])
    func fallbackToleratesMissingConfiguration(fetchFails: Bool) async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: [(2, "zho", "subrip", false)]))
        fake.userConfigurationResult = fetchFails
            ? .failure(FakeJellyfinPlaybackClient.FakeError.reportFailed)
            : .success(userConfiguration(preference: "", mode: .always))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultSubtitleStreamIndex == nil)
    }

    /// The extra round-trip is the price of a rescue, so it only runs when there
    /// is something to rescue.
    @Test("The configuration is fetched only when the server left the default nil and text subs exist", arguments: [
        (2, false), (nil, true),
    ] as [(Int?, Bool)])
    func fallbackFetchesConfigurationOnlyWhenNeeded(serverDefault: Int?, fetches: Bool) async throws {
        let (service, fake) = makeService(source: fallbackSource(
            defaultSubtitleIndex: serverDefault,
            subtitles: [(2, "zho", "subrip", false)]
        ))
        fake.userConfigurationResult = .success(userConfiguration(preference: "zho", mode: .always))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultSubtitleStreamIndex == 2)
        #expect(fake.userConfigurationFetchCount == (fetches ? 1 : 0))
    }

    @Test("A source with no text subtitles never asks for the configuration")
    func fallbackSkippedWithoutTextSubs() async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: [(2, "zho", "pgssub", false)]))
        fake.userConfigurationResult = .success(userConfiguration(preference: "zho", mode: .always))
        _ = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(fake.userConfigurationFetchCount == 0)
    }

    @Test("The audio default is never invented client-side")
    func fallbackLeavesAudioAlone() async throws {
        let (service, fake) = makeService(source: fallbackSource(subtitles: [(2, "zho", "subrip", false)]))
        fake.userConfigurationResult = .success(userConfiguration(preference: "zho", mode: .always))
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.defaultAudioStreamIndex == nil)
    }

    @Test("Empty media sources throws an AppError")
    func emptySourcesThrows() async {
        let fake = FakeJellyfinPlaybackClient()
        var response = PlaybackInfoResponse()
        response.mediaSources = []
        response.playSessionID = "ps-1"
        fake.playbackInfoResult = .success(response)
        let service = PlaybackInfoService(client: fake)
        await #expect(throws: AppError.self) {
            _ = try await service.resolve(
                item: ItemID(rawValue: "item-1"),
                capabilities: caps(),
                startTime: nil
            )
        }
    }
}

/// `clientRendersAllSubtitles` is the single predicate that decides whether the playback
/// engine's own subtitle renderer is blinded. It reads SIDECAR COVERAGE — a stream missing
/// from `subtitleStreamURLs` is, by the server's own answer, one the client cannot draw.
@Suite("ResolvedPlayback — clientRendersAllSubtitles")
struct ClientRendersAllSubtitlesTests {

    private func resolved(text: [Int], image: [Int]) -> ResolvedPlayback {
        func stream(_ index: Int, image isImage: Bool) -> MediaStreamInfo {
            MediaStreamInfo(index: index, kind: .subtitle, displayTitle: "Sub \(index)",
                            language: "eng", codec: isImage ? "pgssub" : "subrip",
                            channels: nil, isExternal: false, isForced: false, isDefault: false)
        }
        return ResolvedPlayback(
            itemID: "i", url: URL(string: "https://x/y.mkv")!, method: .directPlay,
            container: .mkv, videoCodec: .h264, audioCodec: .aac,
            mediaSourceID: "ms", playSessionID: "ps", runtime: nil, startTime: nil,
            mediaStreams: (text.map { stream($0, image: false) } + image.map { stream($0, image: true) })
                .sorted { $0.index < $1.index },
            subtitleStreamURLs: Dictionary(uniqueKeysWithValues: text.map {
                ($0, URL(string: "https://x/sub/\($0).srt")!)
            })
        )
    }

    @Test("true only when every reported subtitle stream has a sidecar to fetch", arguments: [
        (text: [1], image: [Int](), expected: true),      // text only — we draw it all
        (text: [Int](), image: [1], expected: false),     // image only — only the engine can
        (text: [1], image: [2], expected: false),         // mixed — the engine keeps its half
        (text: [1, 3], image: [Int](), expected: true),
    ])
    func coverageDecidesIt(text: [Int], image: [Int], expected: Bool) {
        #expect(resolved(text: text, image: image).clientRendersAllSubtitles == expected)
    }

    /// No subtitle streams at all is NOT "we render them all": the engine's own inventory is
    /// then the only thing there is, and blinding it would strand tracks nothing draws.
    @Test("false when the server reported no subtitle streams")
    func emptyIsNotFullCoverage() {
        #expect(resolved(text: [], image: []).clientRendersAllSubtitles == false)
    }
}
