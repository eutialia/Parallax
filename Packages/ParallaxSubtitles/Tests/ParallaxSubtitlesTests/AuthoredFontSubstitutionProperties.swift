import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// Authored ASS scripts as fansub tools write them: either line ending, the Format columns in
/// any order, fonts nobody ships, and dialogue that mixes scripts and changes font inline.
@Suite("Authored font substitution")
struct AuthoredFontSubstitutionProperties {

    private static let cases = 300

    private static let fontNames = [
        "Arial", "MS Mincho", "SimHei", "Times New Roman", "@DFKai-SB", "Open Sans", "微软雅黑", "宋体",
        "Noto Sans", "Hiragino Mincho ProN",
    ]
    private static let styleValues = [
        "Fontsize": "28", "PrimaryColour": "&H0000FFFF", "Bold": "0", "Alignment": "7", "MarginV": "20",
    ]
    private static let eventValues = [
        "Layer": "0", "Start": "0:00:01.00", "End": "0:00:03.00", "Name": "", "MarginL": "0", "Effect": "",
    ]
    private static let text = ["Hello", "这是简体", "これは", "สวัสดี", " ", ", and a comma", "{\\i1}", "{\\fn}", "\\N", "\\"]
    private static let hints: [String?] = [nil, "ja", "zh-Hans", "zh-Hant"]

    private struct Script {
        let text: String
        let lineEnding: String
        let fontColumn: Int
        let textColumn: Int
        /// Every font the script names, in a style or inline.
        let fonts: Set<String>

    }

    /// Split on the scalar: Swift reads CRLF as one character.
    private static func lines(of script: String) -> [String] {
        script.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    private static func script(_ random: inout SeededGenerator) -> Script {
        var fonts: Set<String> = []
        func font(_ random: inout SeededGenerator) -> String {
            let name = fontNames.randomElement(using: &random)!
            fonts.insert(name.hasPrefix("@") ? String(name.dropFirst()) : name)
            return name
        }

        let styleColumns = (["Name", "Fontname"] + styleValues.keys.sorted()).shuffled(using: &random)
        let styles = (0..<Int.random(in: 1...4, using: &random)).map { "S\($0)" }
        var lines = ["[Script Info]", "; written by a property", "ScriptType: v4.00+", "PlayResX: 640", "PlayResY: 360", ""]
        lines += ["[V4+ Styles]", "Format: " + styleColumns.joined(separator: ", ")]
        for style in styles {
            let row = styleColumns.map { $0 == "Name" ? style : $0 == "Fontname" ? font(&random) : styleValues[$0]! }
            lines.append("Style: " + row.joined(separator: ","))
        }

        let eventColumns = (["Style"] + eventValues.keys.sorted()).shuffled(using: &random) + ["Text"]
        lines += ["", "[Events]", "Format: " + eventColumns.joined(separator: ", ")]
        for _ in 0..<Int.random(in: 1...8, using: &random) {
            let said = (0..<Int.random(in: 1...8, using: &random)).map { _ in
                Int.random(in: 0..<8, using: &random) == 0 ? "{\\fn\(font(&random))}" : text.randomElement(using: &random)!
            }.joined()
            let row = eventColumns.map { $0 == "Style" ? styles.randomElement(using: &random)! : $0 == "Text" ? said : eventValues[$0]! }
            lines.append((Int.random(in: 0..<8, using: &random) == 0 ? "Comment: " : "Dialogue: ") + row.joined(separator: ","))
        }

        let ending = Bool.random(using: &random) ? "\n" : "\r\n"
        return Script(
            text: lines.joined(separator: ending) + ending, lineEnding: ending,
            fontColumn: styleColumns.firstIndex(of: "Fontname")!, textColumn: eventColumns.count - 1, fonts: fonts)
    }

    private static func fields(_ line: String, upTo column: Int = .max) -> [String] {
        line.unicodeScalars.drop { $0 != ":" }.dropFirst().filter { $0 != "\r" }
            .split(separator: ",", maxSplits: column, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    private static let shipped = Set(SubtitleFontBundle.facesByFamily.keys)

    @Test("substitution changes font names and adds font tags, and every other byte of the script stays")
    func onlyFontNamesChange() {
        var random = SeededGenerator(seed: 0x73_7562)
        for run in 0..<Self.cases {
            let script = Self.script(&random)
            let scan = ASSScriptScan.scan(script: script.text)
            let plan = SubtitleFontPlan.build(
                lines: scan.plainLines, styleFamily: SubtitleFontBundle.sansFamily,
                languageHint: Self.hints.randomElement(using: &random)!)

            let out = AuthoredFontSubstitution.applied(to: script.text, plan: plan, scan: scan)

            let context = "run \(run): \(script.text.debugDescription)"
            let before = Self.lines(of: script.text), after = Self.lines(of: out)
            #expect(after.count == before.count, "\(context)")
            for (old, new) in zip(before, after) {
                if old.hasPrefix("Style:") {
                    var was = Self.fields(old), now = Self.fields(new)
                    #expect(Self.shipped.contains(now[script.fontColumn]), "\(context)")
                    was.remove(at: script.fontColumn)
                    now.remove(at: script.fontColumn)
                    #expect(now == was, "\(context)")
                } else if old.hasPrefix("Dialogue:") {
                    let was = Self.fields(old, upTo: script.textColumn), now = Self.fields(new, upTo: script.textColumn)
                    #expect(now.dropLast() == was.dropLast(), "\(context)")
                    let shown = { (field: String) in
                        SubtitleFontTagger.plainLines(of: field).map { $0.replacingOccurrences(of: "\u{2060}", with: "") }
                    }
                    #expect(shown(now[script.textColumn]) == shown(was[script.textColumn]), "\(context)")
                    #expect(new.hasSuffix("\r") == old.hasSuffix("\r"), "\(context)")
                    let resets = { (field: String) in field.components(separatedBy: "{\\fn}").count }
                    #expect(resets(now[script.textColumn]) >= resets(was[script.textColumn]), "\(context): a bare reset got a name")
                    for block in SubtitleFontTagger.tokenize(now[script.textColumn]) {
                        guard case .override(let block) = block else { continue }
                        for name in block.dropFirst().dropLast().components(separatedBy: "\\fn").dropFirst() where !name.isEmpty {
                            #expect(Self.shipped.contains(name), "\(context): \(new.debugDescription)")
                        }
                    }
                } else {
                    #expect(new == old, "\(context)")
                }
            }
        }
    }

    @Test("the fonts read off a script are the ones its styles and its inline changes name")
    func requestedFamiliesAreTheOnesNamed() {
        var random = SeededGenerator(seed: 0x72_6571)
        for run in 0..<Self.cases {
            let script = Self.script(&random)

            #expect(ASSScriptScan.requestedFamilies(in: script.text) == script.fonts, "run \(run): \(script.text.debugDescription)")
        }
    }
}
