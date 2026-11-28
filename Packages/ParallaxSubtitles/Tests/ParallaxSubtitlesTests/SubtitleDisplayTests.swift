import Foundation
import ParallaxSubtitles
import Testing

/// A `SubtitleDisplay` as the player uses it: real subtitle files behind a scripted fetch.
@MainActor
@Suite("SubtitleDisplay", .timeLimit(.minutes(1)))
struct SubtitleDisplayTests {
    private static let english = SubtitleDocument(
        url: URL(string: "https://media.example/Videos/1/ms/Subtitles/2/Stream.srt?api_key=k")!, languageCode: "eng")
    private static let authored = SubtitleDocument(
        url: URL(string: "https://media.example/Videos/1/ms/Subtitles/3/Stream.ass?api_key=k")!, languageCode: "jpn")

    @Test("a subtitle shown again in the same session is not fetched again, and after the session ends it is")
    func fetchedOncePerSession() async throws {
        let srt = try SubtitleFixtureFile.twoLinesSRT.data
        let fetch = ScriptedSubtitleFetch { _ in .data(srt) }
        let display = SubtitleDisplay(fetch: fetch.fetch)
        let events = DisplayEvents(of: display)

        display.show(Self.english)
        await events.reach(1)
        display.clear()
        display.show(Self.english)
        await events.reach(2)
        #expect(await fetch.requested == [Self.english.url])

        display.endSession()
        display.show(Self.english)
        await events.reach(3)
        #expect(await fetch.requested == [Self.english.url, Self.english.url])
        #expect(events.all == Array(repeating: .landed(Self.english.url), count: 3))
    }

    @Test("an ASS document the server won't serve as written is fetched once more as WebVTT, with its query kept, and drawn")
    func refusedASSFallsBackToWebVTT() async throws {
        let vtt = try SubtitleFixtureFile.twoLinesVTT.data
        let fetch = ScriptedSubtitleFetch { url in url.pathExtension == "vtt" ? .data(vtt) : .rejected }
        let display = SubtitleDisplay(fetch: fetch.fetch)
        let events = DisplayEvents(of: display)

        display.show(Self.authored)
        await events.reach(1)

        let asWebVTT = try #require(URL(string: "https://media.example/Videos/1/ms/Subtitles/3/Stream.vtt?api_key=k"))
        #expect(await fetch.requested == [Self.authored.url, asWebVTT])
        #expect(events.all == [.landed(Self.authored.url)])
        #expect(display.shownInfo == SidecarSubtitleInfo(format: .vtt, byteCount: vtt.count))
        let drawn = try await inkDrawn(by: try #require(display.renderer), at: 2)
        #expect(drawn.pixels.count > 100)
    }

    @Test("my style reaches SRT and WebVTT subtitles, and an ASS subtitle keeps its author's look")
    func styleReachesConvertedSubtitlesOnly() async throws {
        let srt = try SubtitleFixtureFile.twoLinesSRT.data
        let vtt = try SubtitleFixtureFile.twoLinesVTT.data
        let ass = try SubtitleFixtureFile.yellowTopLeftASS.data
        let fetch = ScriptedSubtitleFetch { url in
            switch url.pathExtension {
            case "srt": .data(srt)
            case "vtt": .data(vtt)
            default: .data(ass)
            }
        }
        let display = SubtitleDisplay(fetch: fetch.fetch)
        let events = DisplayEvents(of: display)
        display.applyAppearance(converted: SubtitleStyleOverride(primaryColor: SubtitleColor(red: 1, green: 0, blue: 0)))
        let isRed = { (pixel: RenderedPixels.Pixel) in pixel.red > 200 && pixel.green < 60 && pixel.blue < 60 }
        let isYellow = { (pixel: RenderedPixels.Pixel) in pixel.red > 200 && pixel.green > 200 && pixel.blue < 60 }
        let isWhite = { (pixel: RenderedPixels.Pixel) in pixel.red > 200 && pixel.green > 200 && pixel.blue > 200 }

        let webVTT = SubtitleDocument(
            url: URL(string: "https://media.example/Videos/1/ms/Subtitles/4/Stream.vtt?api_key=k")!, languageCode: "eng")
        for (place, converted) in [Self.english, webVTT].enumerated() {
            display.show(converted)
            await events.reach(place + 1)
            let drawn = try await inkDrawn(by: try #require(display.renderer), at: 2)
            #expect(drawn.pixels.contains(where: isRed), "\(converted.url.pathExtension) is not drawn in my color")
            #expect(!drawn.pixels.contains(where: isWhite), "\(converted.url.pathExtension) is drawn in the default color")
        }

        display.show(Self.authored)
        await events.reach(3)
        let authored = try await inkDrawn(by: try #require(display.renderer), at: 2)
        #expect(authored.pixels.contains(where: isYellow))
        #expect(!authored.pixels.contains(where: isRed))
        // The author put it in the top-left corner, and it stays there.
        #expect(authored.frame.imageRect.maxX < 320 && authored.frame.imageRect.maxY < 120)
    }

    @Test("a subtitle shown while another is still fetching is the one drawn, and the older answer draws nothing")
    func newerPickWins() async throws {
        let srt = try SubtitleFixtureFile.twoLinesSRT.data
        let ass = try SubtitleFixtureFile.yellowTopLeftASS.data
        let older = FetchGate()
        let newer = FetchGate()
        let fetch = ScriptedSubtitleFetch { url in
            if url.pathExtension == "srt" {
                await older.passed()
                return .data(srt)
            }
            await newer.passed()
            return .data(ass)
        }
        let display = SubtitleDisplay(fetch: fetch.fetch)
        let events = DisplayEvents(of: display)

        display.show(Self.english)
        #expect(display.loading == Self.english)
        display.show(Self.authored)
        #expect(display.loading == Self.authored)
        // The older answer arrives first, and late.
        await older.open()
        await newer.open()
        await events.reach(1)

        #expect(events.all == [.landed(Self.authored.url)])
        #expect(display.loading == nil)
        #expect(display.shownInfo == SidecarSubtitleInfo(format: .ass, byteCount: ass.count))
    }
}
