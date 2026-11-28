import Foundation
import JellyfinAPI
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing

/// The subtitles a Jellyfin title hands the player, and the subtitle settings a pick leaves on the
/// server, through the real playback client over `FakeJellyfinServer`.
@Suite("Subtitles from a Jellyfin server")
struct PlaybackInfoServiceSubtitleTests {

    private static let user = "ana"
    private static let title = "Heat"

    private static func server() -> FakeJellyfinServer {
        FakeJellyfinServer().user(user).library("Films").movie(title, in: "Films")
    }

    private static func service(for server: FakeJellyfinServer) -> PlaybackInfoService {
        PlaybackInfoService(
            client: DefaultJellyfinPlaybackClient(
                session: server.session(signedInAs: user),
                identity: JellyfinFixtures.identity(),
                onTokenRejected: { _ in },
                sessionConfiguration: StubHTTPTransport.configuration
            ),
            clock: TestClock()
        )
    }

    private static func resolve(
        on server: FakeJellyfinServer, selection: StreamSelection? = nil
    ) async throws -> ResolvedPlayback {
        try await service(for: server).resolve(
            item: ItemID(rawValue: server.itemID(of: title)), capabilities: JellyfinFixtures.caps(),
            startTime: nil, selection: selection)
    }

    private static func fetch(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession(configuration: StubHTTPTransport.configuration).data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// One subtitle stream as a Jellyfin server writes it into a PlaybackInfo answer.
    struct Stream: Sendable, CustomTestStringConvertible {
        var index: Int
        var language: String? = "eng"
        var codec = "subrip"
        var forced = false
        var fields: [String: String] = [:]

        var json: String {
            let base: [String: String] = [
                "\"Index\"": "\(index)", "\"Type\"": "\"Subtitle\"", "\"Codec\"": "\"\(codec)\"",
                "\"IsForced\"": "\(forced)", "\"Language\"": language.map { "\"\($0)\"" } ?? "null",
            ]
            let all = base.merging(fields.map { ("\"\($0.key)\"", $0.value) }) { _, field in field }
            return "{" + all.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        }

        var testDescription: String { "\(index) \(codec) \(language ?? "nil")\(forced ? " forced" : "")" }
    }

    private static func answer(_ streams: [Stream], serverDefault: Int? = nil) -> String {
        let video = #"{"Index": 0, "Type": "Video", "Codec": "h264"}"#
        return """
        {"PlaySessionId": "ps-1", "MediaSources": [{
            "Id": "ms-1", "Container": "mkv", "RunTimeTicks": 72000000000,
            "DefaultSubtitleStreamIndex": \(serverDefault.map(String.init) ?? "null"),
            "MediaStreams": [\(([video] + streams.map(\.json)).joined(separator: ", "))]
        }]}
        """
    }

    private static func server(answering streams: [Stream], serverDefault: Int? = nil) -> FakeJellyfinServer {
        server().playbackInfo(of: title, answers: answer(streams, serverDefault: serverDefault))
    }

    // MARK: - Sidecars

    @Test("each text subtitle comes with a link that fetches the file the server holds, as written; an image subtitle has none and stays in the stream list")
    func textSubtitlesFetchAsWritten() async throws {
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nThe heat is on.\n"
        let ass = "[Script Info]\nScriptType: v4.00+\n"
        let server = Self.server().streams(Self.title, subtitles: [
            .init(language: "eng", title: "English", .srt(srt)),
            .init(language: "jpn", title: "Japanese", .ass(ass)),
            .init(language: "eng", title: "English PGS", .image),
        ])

        let resolved = try await Self.resolve(on: server)

        #expect(Set(resolved.subtitleStreamURLs.keys) == [2, 3])
        #expect(try await Self.fetch(#require(resolved.subtitleStreamURLs[2])) == srt)
        #expect(try await Self.fetch(#require(resolved.subtitleStreamURLs[3])) == ass)
        #expect(resolved.mediaStreams.filter { $0.kind == .subtitle }.map(\.index) == [2, 3, 4])
    }

    /// The server's own conversion runs through ffmpeg, which strips ASS styling and SRT
    /// placement on the way to VTT, so a format the player draws natively is asked for verbatim.
    @Test("a text subtitle's link asks for the file in its own format when the player draws it, else in WebVTT, with cue times kept absolute",
          arguments: [("subrip", "srt"), ("SRT", "srt"), ("ass", "ass"), ("ssa", "ssa"), ("mov_text", "vtt"), ("webvtt", "vtt")])
    func sidecarLinkShape(codec: String, format: String) async throws {
        let server = Self.server(answering: [Stream(index: 1, codec: codec)])

        let url = try #require(try await Self.resolve(on: server).subtitleStreamURLs[1])
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(url.path == "/Videos/\(server.itemID(of: Self.title))/ms-1/Subtitles/1/Stream.\(format)")
        #expect(query.contains { $0.name.lowercased() == "copytimestamps" && $0.value == "true" })
        #expect(query.contains { $0.name == "ApiKey" && $0.value?.isEmpty == false })
    }

    @Test("an image subtitle has no link to fetch, whichever name the server gives its codec",
          arguments: MediaStreamInfo.imageSubtitleCodecs + ["PGSSUB"])
    func imageSubtitleHasNoLink(codec: String) async throws {
        let resolved = try await Self.resolve(on: Self.server(answering: [Stream(index: 1, codec: codec)]))

        #expect(resolved.subtitleStreamURLs.isEmpty)
        #expect(resolved.mediaStreams.contains { $0.index == 1 && $0.kind == .subtitle })
    }

    @Test("a subtitle stream reaches the player with the title, language, delivery and hearing-impaired flag the server reports")
    func subtitleStreamFields() async throws {
        let server = Self.server(answering: [Stream(index: 1, language: "zh-Hans", forced: true, fields: [
            "Title": "\"Simplified SDH\"", "DisplayTitle": "\"Chinese (Simplified) - SDH - SUBRIP\"",
            "IsHearingImpaired": "true", "DeliveryMethod": "\"External\"", "IsExternal": "true",
        ])])

        let stream = try #require(try await Self.resolve(on: server).mediaStreams.first { $0.kind == .subtitle })

        #expect(stream.index == 1)
        #expect(stream.title == "Simplified SDH")
        #expect(stream.displayTitle == "Chinese (Simplified) - SDH - SUBRIP")
        #expect(stream.language == "zh-Hans")
        #expect(stream.codec == "subrip")
        #expect(stream.subtitleDeliveryMethod == "External")
        #expect(stream.isHearingImpaired)
        #expect(stream.isForced)
        #expect(stream.isExternal)
    }

    /// When the player draws every subtitle itself, the engine's own renderer is blinded; one
    /// subtitle only the engine can show keeps it on.
    @Test("the player draws every subtitle itself only when each one the title has is text",
          arguments: [
              ([.text], true), ([.image], false), ([.text, .image], false), ([.text, .text], true), ([], false),
          ] as [([SubtitleKind], Bool)])
    func clientRendersAllSubtitles(kinds: [SubtitleKind], expected: Bool) async throws {
        let server = Self.server().streams(Self.title, subtitles: kinds.map { kind in
            switch kind {
            case .text: .init(language: "eng", title: "English", .srt("1\n00:00:01,000 --> 00:00:02,000\nHi\n"))
            case .image: .init(language: "eng", title: "English PGS", .image)
            }
        })

        #expect(try await Self.resolve(on: server).clientRendersAllSubtitles == expected)
    }

    enum SubtitleKind: Sendable { case text, image }

    // MARK: - Default subtitle

    /// Jellyfin matches a stored alpha-3 against dashless tags only, so a `zh-Hans` stream gets
    /// no default under "zho" from the server; the client finds it across spellings.
    @Test("with no default from the server, the subtitle in the user's language shows, a script-tagged preference picking its script over stream order",
          arguments: [("zho", 2), ("chi", 2), ("zh-Hans", 3), ("zh_hans", 3), ("zh-Hant", 2), ("jpn", nil)] as [(String, Int?)])
    func defaultFollowsTheUsersLanguage(preference: String, expected: Int?) async throws {
        let server = Self.server(answering: [
            Stream(index: 2, language: "zh-hant"), Stream(index: 3, language: "zh-hans"), Stream(index: 4, language: "zh-Hans"),
        ])
            .subtitleSettings(language: preference, mode: .always, for: Self.user)

        #expect(try await Self.resolve(on: server).defaultSubtitleStreamIndex == expected)
    }

    @Test("no subtitle shows by default unless the user set subtitles to always show",
          arguments: [SubtitlePlaybackMode.none, .default, .onlyForced, .smart, nil] as [SubtitlePlaybackMode?])
    func defaultNeedsAlways(mode: SubtitlePlaybackMode?) async throws {
        let server = Self.server(answering: [Stream(index: 2, language: "zho")])
            .subtitleSettings(language: "zho", mode: mode, for: Self.user)

        #expect(try await Self.resolve(on: server).defaultSubtitleStreamIndex == nil)
    }

    @Test("a forced or image subtitle never shows by default, and a title with nothing else never reads the user's settings",
          arguments: [Stream(index: 2, language: "zho", forced: true), Stream(index: 2, language: "zho", codec: "pgssub")])
    func defaultSkipsForcedAndImage(stream: Stream) async throws {
        let server = Self.server(answering: [stream, Stream(index: 3, language: "jpn")])
            .subtitleSettings(language: "zho", mode: .always, for: Self.user)
        let alone = Self.server(answering: [stream]).subtitleSettings(language: "zho", mode: .always, for: Self.user)

        #expect(try await Self.resolve(on: server).defaultSubtitleStreamIndex == nil)
        #expect(try await Self.resolve(on: alone).defaultSubtitleStreamIndex == nil)
        #expect(alone.configurationReads == 0)
    }

    @Test("with no language set, or settings the server fails to read, the title still plays with no subtitle shown",
          arguments: [false, true])
    func defaultWithoutSettings(readFails: Bool) async throws {
        let server = Self.server(answering: [Stream(index: 2, language: "zho")])
            .subtitleSettings(language: readFails ? "zho" : "", mode: .always, for: Self.user)
        if readFails { server.failConfigurationReads() }

        let resolved = try await Self.resolve(on: server)

        #expect(resolved.defaultSubtitleStreamIndex == nil)
        #expect(server.configurationReads == 1)
    }

    @Test("the server's own default subtitle shows without reading the user's settings",
          arguments: [(2 as Int?, 0), (nil, 1)])
    func serverDefaultWins(serverDefault: Int?, reads: Int) async throws {
        let server = Self.server(answering: [Stream(index: 2, language: "zho")], serverDefault: serverDefault)
            .subtitleSettings(language: "zho", mode: .always, for: Self.user)

        #expect(try await Self.resolve(on: server).defaultSubtitleStreamIndex == 2)
        #expect(server.configurationReads == reads)
    }

    // MARK: - What the server is asked for

    struct Pick: Sendable {
        var audio: Int?
        var subtitle: Int
        var burnsIn = false
    }

    /// The picked indices only count beside the source they index into, and a burned-in subtitle
    /// has to be painted into the picture, which a copied video stream cannot carry.
    @Test("a subtitle pick reaches the server with its source, and only a burn-in pick withdraws the video stream copy",
          arguments: [
              (Pick(audio: 1, subtitle: 2), true),
              (Pick(audio: nil, subtitle: 3, burnsIn: true), false),
              (Pick(audio: nil, subtitle: -1), true),
              (nil, true),
          ] as [(Pick?, Bool)])
    func selectionReachesTheServer(pick: Pick?, copiesVideo: Bool) async throws {
        let server = Self.server().streams(Self.title, by: .transcode, subtitles: [
            .init(language: "eng", title: "English", .srt("")), .init(language: "eng", title: "English PGS", .image),
        ])
        let source = try await Self.resolve(on: server).mediaSourceID
        let selection = pick.map {
            StreamSelection(mediaSourceID: source, audioStreamIndex: $0.audio, subtitleStreamIndex: $0.subtitle,
                            burnsInSubtitle: $0.burnsIn)
        }

        _ = try await Self.resolve(on: server, selection: selection)

        let request = try #require(server.playbackRequests.last)
        #expect(request.mediaSourceID == selection?.mediaSourceID)
        #expect(request.audioStreamIndex == selection?.audioStreamIndex)
        #expect(request.subtitleStreamIndex == selection?.subtitleStreamIndex)
        #expect(request.allowsVideoStreamCopy == copiesVideo)
    }

    /// The server matches a subtitle profile by string equality against the stream's codec, and
    /// an in-manifest WebVTT mis-times on fMP4 segments and draws under the player's own.
    @Test("the device tells the server it fetches text subtitles itself, needs image subtitles burned in under every codec name, and takes none in the stream")
    func deviceProfileSubtitles() async throws {
        let server = Self.server()

        _ = try await Self.resolve(on: server)

        let profile = try #require(server.playbackDeviceProfiles.last)
        let subtitles = profile.subtitleProfiles ?? []
        let burned = subtitles.filter { $0.method == .encode }.compactMap(\.format)
        #expect(["vtt", "srt", "ass"].allSatisfy { format in
            subtitles.contains { $0.format == format && $0.method == .external }
        })
        #expect(burned.sorted() == MediaStreamInfo.imageSubtitleCodecs.sorted())
        #expect(!subtitles.contains { $0.method == .hls })
        #expect(profile.transcodingProfiles?.isEmpty == false)
        #expect(profile.transcodingProfiles?.allSatisfy { $0.enableSubtitlesInManifest == false } == true)
    }

    // MARK: - Remembering a pick

    private static func remember(_ language: String?, on server: FakeJellyfinServer) async {
        await service(for: server).rememberTrackSelection(.subtitles(languageCode: language))
    }

    @Test("picking a subtitle saves its language, and turns subtitles on only for a user who had them off",
          arguments: [
              (SubtitlePlaybackMode.none, .always),
              (nil, .always), (.smart, .smart), (.onlyForced, .onlyForced), (.default, .default), (.always, .always),
          ] as [(SubtitlePlaybackMode?, SubtitlePlaybackMode?)])
    func pickSavesLanguage(mode: SubtitlePlaybackMode?, saved: SubtitlePlaybackMode?) async {
        let server = Self.server().subtitleSettings(language: "eng", mode: mode, for: Self.user)

        await Self.remember("fre", on: server)

        #expect(server.subtitleLanguage(of: Self.user) == "fra")
        #expect(server.subtitleMode(of: Self.user) == saved)
    }

    /// Jellyfin matches a script- or region-carrying preference exactly, so it is saved in the
    /// server's own spelling; everything else is saved as alpha-3, which the server expands.
    @Test("a picked subtitle's language is saved in the spelling the server matches streams by",
          arguments: [
              ("zh-Hans", "zh-Hans"), ("zh_Hans", "zh-Hans"), ("ZH-HANT", "zh-Hant"), ("pt-br", "pt-BR"),
              ("es-419", "es-419"), ("eng", "eng"), ("en", "eng"), ("zh-CN", "zh-CN"), ("zh", "zho"), ("en-US", "eng"),
          ])
    func pickSavedInTheServersSpelling(picked: String, saved: String) async {
        let server = Self.server().subtitleSettings(language: "zho", mode: .always, for: Self.user)

        await Self.remember(picked, on: server)

        #expect(server.subtitleLanguage(of: Self.user) == saved)
    }

    @Test("picking the subtitle language already saved, in any letter case, writes nothing back",
          arguments: [("zh-hans", "zh-Hans"), ("ENG", "en"), ("deu", "ger")])
    func repeatPickWritesNothing(stored: String, picked: String) async {
        let server = Self.server().subtitleSettings(language: stored, mode: .always, for: Self.user)

        await Self.remember(picked, on: server)

        #expect(server.configurationWrites == 0)
        #expect(server.subtitleLanguage(of: Self.user) == stored)
    }

    @Test("turning subtitles off saves them off, once")
    func offIsRememberedOnce() async {
        let server = Self.server().subtitleSettings(language: "eng", mode: .always, for: Self.user)

        await Self.remember(nil, on: server)
        await Self.remember(nil, on: server)

        #expect(server.subtitleMode(of: Self.user) == SubtitlePlaybackMode.none)
        #expect(server.subtitleLanguage(of: Self.user) == "eng")
        #expect(server.configurationWrites == 1)
    }

    @Test("a user who told the server not to remember subtitle picks keeps their settings", arguments: ["fre", nil] as [String?])
    func optOutHolds(picked: String?) async {
        let server = Self.server().subtitleSettings(language: "eng", mode: .always, remembersPicks: false, for: Self.user)

        await Self.remember(picked, on: server)

        #expect(server.configurationWrites == 0)
        #expect(server.subtitleLanguage(of: Self.user) == "eng")
        #expect(server.subtitleMode(of: Self.user) == .always)
    }

    @Test("settings the server fails to read are never written over")
    func failedReadWritesNothing() async {
        let server = Self.server().subtitleSettings(language: "eng", mode: .always, for: Self.user)
        server.failConfigurationReads()

        await Self.remember("fre", on: server)

        #expect(server.configurationWrites == 0)
    }
}
