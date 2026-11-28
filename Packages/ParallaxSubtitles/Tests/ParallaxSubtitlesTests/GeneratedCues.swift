import Foundation
import ParallaxCoreTestSupport
@testable import ParallaxSubtitles

/// A cue as a property generates it, before a file format spells it.
struct GeneratedCue {
    /// Milliseconds.
    let start: Int
    let end: Int
    let lines: [String]

    static func seconds(_ milliseconds: Int) -> Double {
        Double(milliseconds / 1000) + Double(milliseconds % 1000) / 1000
    }

    var event: ASSEvent {
        ASSEvent(start: Self.seconds(start), end: Self.seconds(end), text: lines.joined(separator: "\\N"))
    }

    var endsInANumber: Bool { Int(lines[lines.count - 1]) != nil }

    /// Characters no format reads as markup, timing or an entity.
    private static let alphabet = Array("abcXYZ字幕测試かな한 0123456789")

    static func line(_ random: inout SeededGenerator) -> String {
        if Int.random(in: 0..<8, using: &random) == 0 {
            return String(Int.random(in: 0...9999, using: &random))
        }
        let text = String((0..<Int.random(in: 1...12, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "x" : text
    }

    /// A cue inside the hundred hours a timestamp may name.
    static func cue(_ random: inout SeededGenerator) -> GeneratedCue {
        let start = Int.random(in: 0..<359_998_000, using: &random)
        let length = Int.random(in: 0..<4, using: &random) == 0 ? Int.random(in: 0...3_600_000, using: &random) : Int.random(in: 0...9000, using: &random)
        return GeneratedCue(
            start: start, end: min(start + length, 359_998_999),
            lines: (0..<Int.random(in: 1...3, using: &random)).map { _ in line(&random) })
    }

    static func cues(_ random: inout SeededGenerator) -> [GeneratedCue] {
        (0..<Int.random(in: 1...20, using: &random)).map { _ in cue(&random) }
    }

    /// `HH:MM:SS,mmm`, or `MM:SS,mmm` when `short` is set and the hour is zero.
    static func timestamp(_ milliseconds: Int, mark: String, short: Bool = false) -> String {
        let seconds = milliseconds / 1000
        let tail = String(format: "%02d:%02d%@%03d", (seconds / 60) % 60, seconds % 60, mark, milliseconds % 1000)
        return short && seconds < 3600 ? tail : String(format: "%02d:", seconds / 3600) + tail
    }
}

enum GeneratedFile {
    static let lineEndings = ["\n", "\r\n", "\r"]

    static func mark(_ random: inout SeededGenerator) -> String {
        Bool.random(using: &random) ? "," : "."
    }

    static func byteOrderMark(_ random: inout SeededGenerator) -> String {
        Int.random(in: 0..<4, using: &random) == 0 ? "\u{FEFF}" : ""
    }
}
