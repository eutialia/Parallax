import Testing
import Foundation
import CoreMedia
import ParallaxPlayback

/// Seconds off a cue time. Shared by every subtitle-parser suite — it used to be
/// redeclared privately in each one.
func cueSeconds(_ time: CMTime) -> Double { CMTimeGetSeconds(time) }

/// The behaviours BOTH sidecar parsers owe their single consumer
/// (`activeSubtitleCues` → `SubtitleOverlayView`), which cannot tell SRT from WebVTT.
/// Previously these were copy-pasted between `SRTParserTests` and `WebVTTParserTests`.
enum SubtitleParserKind: String, CaseIterable, CustomTestStringConvertible {
    case srt
    case webVTT

    var testDescription: String { rawValue }

    func parse(_ string: String) -> [SubtitleCue] {
        switch self {
        case .srt: SRTParser.parse(string)
        case .webVTT: WebVTTParser.parse(string)
        }
    }

    func parse(data: Data) -> [SubtitleCue] {
        switch self {
        case .srt: SRTParser.parse(data: data)
        case .webVTT: WebVTTParser.parse(data: data)
        }
    }

    /// "Later" at 0:10 written *before* "Earlier" at 0:01.
    var outOfOrderSource: String {
        switch self {
        case .srt:
            """
            1
            00:00:10,000 --> 00:00:12,000
            Later

            2
            00:00:01,000 --> 00:00:02,000
            Earlier

            """
        case .webVTT:
            """
            WEBVTT

            00:00:10.000 --> 00:00:12.000
            Later

            00:00:01.000 --> 00:00:02.000
            Earlier
            """
        }
    }

    /// One cue, text "Hi", starting at 1.0s.
    var singleCueSource: String {
        switch self {
        case .srt: "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"
        case .webVTT: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi"
        }
    }

    /// Structurally valid but carrying no cue at all.
    var cuelessSource: String {
        switch self {
        case .srt: "1\n\n2\n\n"
        case .webVTT: "WEBVTT\n\n"
        }
    }
}

@Suite("Subtitle parser contract")
struct SubtitleParserContractTests {

    /// The overlay binary-searches the cue list by start time, so an out-of-order file
    /// would make cues vanish rather than merely appear late.
    @Test("cues are re-sorted ascending by start time", arguments: SubtitleParserKind.allCases)
    func sortsByStart(kind: SubtitleParserKind) {
        #expect(kind.parse(kind.outOfOrderSource).map(\.text) == ["Earlier", "Later"])
    }

    /// A garbled or wrong-format sidecar must degrade to "no subtitles", never throw or
    /// emit junk cues — it must not be able to break playback.
    @Test("empty, non-subtitle and cueless input yield no cues",
          arguments: SubtitleParserKind.allCases)
    func emptyAndGarbage(kind: SubtitleParserKind) {
        #expect(kind.parse("").isEmpty)
        #expect(kind.parse("not a subtitle file at all").isEmpty)
        #expect(kind.parse(kind.cuelessSource).isEmpty)
    }

    @Test("the Data overload decodes UTF-8 and parses identically to the String overload",
          arguments: SubtitleParserKind.allCases)
    func dataOverloadMatchesString(kind: SubtitleParserKind) {
        let source = kind.singleCueSource
        let fromData = kind.parse(data: Data(source.utf8))
        #expect(fromData == kind.parse(source))
        #expect(fromData.map(\.text) == ["Hi"])
        #expect(fromData.first.map { cueSeconds($0.start) } == 1.0)
    }

    /// Non-UTF-8 bytes are a real sidecar case (legacy CP1252 SRTs); the contract is
    /// "no cues", not a crash.
    @Test("undecodable bytes yield no cues", arguments: SubtitleParserKind.allCases)
    func invalidUTF8YieldsNoCues(kind: SubtitleParserKind) {
        #expect(kind.parse(data: Data([0xFF, 0xFE, 0xFF])).isEmpty)
    }
}
