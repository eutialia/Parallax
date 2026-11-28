import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxPlayback

/// A Jellyfin manifest option joined to the server's streams: the manifest names a language in
/// BCP-47, the server in ISO 639-2, often in its bibliographic form.
@Suite("Jellyfin track naming")
struct JellyfinTrackMatcherProperties {

    private static let cases = 500

    /// Every spelling of one language that either side writes.
    private static let languages: [[String]] = [
        ["en", "eng", "en-US"],
        ["fr", "fra", "fre"],
        ["de", "deu", "ger"],
        ["zh", "zho", "chi", "zh-Hant", "zh-Hans"],
        ["ja", "jpn"],
        ["und"],
    ]
    private static let placeholders = ["Unknown", "UNKNOWN", "und", "Undetermined", "", "   "]
    private static let ownNames = ["Chinese, Traditional (Taiwan)", "English", " Director's Commentary ", "Signs"]

    private struct Option: CustomStringConvertible {
        let kind: AVKitTrackNaming.Kind
        let displayName: String
        /// Which entry of `languages` the option's language spells, if it has one.
        let language: Int?
        let spelling: String?
        let ordinal: Int
        let count: Int
        let defaultStreamIndex: Int?

        var description: String {
            "\(kind) \(displayName.debugDescription) \(spelling ?? "nil") #\(ordinal)/\(count) default \(defaultStreamIndex.map(String.init) ?? "nil")"
        }
    }

    private struct Stream: CustomStringConvertible {
        let info: MediaStreamInfo
        let language: Int?

        var description: String { "\(info.index) \(info.kind) \(info.language ?? "nil") \(info.title ?? "nil")" }
    }

    private static func language(_ random: inout SeededGenerator) -> (Int, String)? {
        guard Int.random(in: 0..<5, using: &random) > 0 else { return nil }
        let group = Int.random(in: 0..<languages.count, using: &random)
        return (group, languages[group].randomElement(using: &random)!)
    }

    private static func streams(_ random: inout SeededGenerator) -> [Stream] {
        let indexes = Array(0..<12).shuffled(using: &random).prefix(Int.random(in: 0...6, using: &random))
        return indexes.map { index in
            let language = language(&random)
            let kind: MediaStreamInfo.Kind = [.audio, .subtitle, .video].randomElement(using: &random)!
            return Stream(
                info: MediaStreamInfo(
                    index: index, kind: kind,
                    displayTitle: Bool.random(using: &random) ? "Track - \(index) - Default" : nil,
                    title: Bool.random(using: &random) ? "Title \(index)" : nil,
                    language: language?.1, codec: "aac", channels: 2,
                    isExternal: false, isForced: false, isDefault: false),
                language: language?.0)
        }
    }

    private static func option(_ random: inout SeededGenerator, streams: [Stream], named names: [String]) -> Option {
        let language = language(&random)
        let count = Int.random(in: 1...3, using: &random)
        let defaultStreamIndex: Int? = switch Int.random(in: 0..<3, using: &random) {
        case 0: nil
        case 1: streams.randomElement(using: &random)?.info.index
        default: Int.random(in: 0..<12, using: &random)
        }
        return Option(
            kind: Bool.random(using: &random) ? .audio : .subtitle,
            displayName: names.randomElement(using: &random)!,
            language: language?.0, spelling: language?.1,
            ordinal: Int.random(in: 1...count, using: &random), count: count,
            defaultStreamIndex: defaultStreamIndex)
    }

    private static func sameKind(_ kind: AVKitTrackNaming.Kind, _ stream: Stream) -> Bool {
        switch kind {
        case .audio: stream.info.kind == .audio
        case .subtitle: stream.info.kind == .subtitle
        }
    }

    /// The server stream an option is, worked out from which language each side spells: a lone
    /// rendition is the server's default stream, else the only stream of its kind; otherwise the
    /// one stream of its kind in the option's language, and none when two share it.
    private static func expectedStream(for option: Option, in streams: [Stream]) -> MediaStreamInfo? {
        let candidates = streams.filter { sameKind(option.kind, $0) }
        if option.count == 1 {
            if let chosen = candidates.first(where: { $0.info.index == option.defaultStreamIndex }) { return chosen.info }
            if candidates.count == 1 { return candidates[0].info }
        }
        guard let language = option.language else { return nil }
        let sameLanguage = candidates.filter { $0.language == language }
        return sameLanguage.count == 1 ? sameLanguage[0].info : nil
    }

    private static func matched(_ option: Option, _ streams: [Stream]) -> MediaStreamInfo? {
        JellyfinTrackMatcher.matchedStream(
            kind: option.kind, optionLanguage: option.spelling, optionCount: option.count,
            streams: streams.map(\.info), defaultStreamIndex: option.defaultStreamIndex)
    }

    private static func name(_ option: Option, _ streams: [Stream]) -> String {
        JellyfinTrackMatcher.name(
            kind: option.kind, optionDisplayName: option.displayName, optionLanguage: option.spelling,
            ordinal: option.ordinal, optionCount: option.count,
            streams: streams.map(\.info), defaultStreamIndex: option.defaultStreamIndex)
    }

    @Test("an option joins the server stream its language or the server's default makes it, of its own kind, and none when the language is shared")
    func optionJoinsItsOwnStream() {
        var random = SeededGenerator(seed: 0x6A_6F696E)
        for run in 0..<Self.cases {
            let streams = Self.streams(&random)
            let option = Self.option(&random, streams: streams, named: Self.placeholders)

            #expect(Self.matched(option, streams) == Self.expectedStream(for: option, in: streams),
                    "run \(run): \(option) in \(streams)")
        }
    }

    @Test("an option the manifest named keeps that name, whatever the server lists")
    func manifestNameWins() {
        var random = SeededGenerator(seed: 0x6F_776E)
        for run in 0..<Self.cases {
            let streams = Self.streams(&random)
            let option = Self.option(&random, streams: streams, named: Self.ownNames)

            #expect(Self.name(option, streams) == option.displayName.trimmingCharacters(in: .whitespaces),
                    "run \(run): \(option) in \(streams)")
        }
    }

    @Test("an option the manifest left unnamed takes its server stream's name, else its language's, else its kind and place")
    func unnamedOptionBorrowsAName() {
        var random = SeededGenerator(seed: 0x75_6E6E)
        for run in 0..<Self.cases {
            let streams = Self.streams(&random)
            let option = Self.option(&random, streams: streams, named: Self.placeholders)
            let place = "\(option.kind == .audio ? "Audio" : "Subtitle") \(option.ordinal)"

            let expected = Self.expectedStream(for: option, in: streams)?.preferredMenuName()
                ?? TrackDisplay.languageName(option.spelling) ?? place

            #expect(Self.name(option, streams) == expected, "run \(run): \(option) in \(streams)")
        }
    }
}
