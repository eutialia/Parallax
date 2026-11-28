import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

@Suite("Cue markup")
struct CueMarkupProperties {

    private static let cases = 1000

    /// Everything libass reads specially in event text, and the characters around it.
    private static let alphabet: [Character] = ["\\", "{", "}", "N", "n", "h", "x", "喵", "\n", "\u{2060}", " "]

    private static func text(_ random: inout SeededGenerator, adding extra: [String] = []) -> String {
        (0..<Int.random(in: 0...16, using: &random)).map { _ in
            !extra.isEmpty && Int.random(in: 0..<6, using: &random) == 0
                ? extra.randomElement(using: &random)! : String(alphabet.randomElement(using: &random)!)
        }.joined()
    }

    /// The text libass shows for an event's Text field. It reads `\N` and `\n` as a line
    /// break, `\{` and `\}` as braces, `\h` as a hard space and `{...}` as an override block;
    /// any other backslash is itself. A word joiner draws nothing.
    private static func shown(_ field: String) -> String {
        var out = ""
        var rest = Substring(field)
        while let character = rest.first {
            if character == "{", let close = rest.firstIndex(of: "}") {
                rest = rest[rest.index(after: close)...]
                continue
            }
            if character == "\\", let next = rest.dropFirst().first, let read = ["N": "\n", "n": "\n", "{": "{", "}": "}", "h": "\u{A0}", "\u{2060}": "\\"][next] {
                out += read
                rest = rest.dropFirst(2)
                continue
            }
            out.append(character)
            rest = rest.dropFirst()
        }
        return out
    }

    @Test("escaped text reads back as what the author wrote, and opens no override block")
    func escapedTextReadsBack() {
        var random = SeededGenerator(seed: 0x65_7363)
        for run in 0..<Self.cases {
            let source = Self.text(&random)

            let escaped = CueMarkup.escape(source)

            #expect(Self.shown(escaped) == source, "run \(run): \(source.debugDescription)")
            let characters = Array(escaped)
            #expect(characters.indices.allSatisfy { index in
                (characters[index] != "{" && characters[index] != "}") || (index > 0 && characters[index - 1] == "\\")
            }, "run \(run): \(escaped.debugDescription)")
        }
    }

    @Test("a field splits into tokens that spell it back, and a backslash is an escape only before N, n, h or a brace")
    func tokensSpellTheField() {
        var random = SeededGenerator(seed: 0x74_6F6B)
        for run in 0..<Self.cases {
            let field = Self.text(&random, adding: ["{\\an8}", "{\\fnArial}", "{\\i1}"])

            let tokens = SubtitleFontTagger.tokenize(field)

            let context = "run \(run): \(field.debugDescription)"
            let literals = tokens.map { token in
                switch token {
                case .override(let literal), .escaped(let literal), .lineBreak(let literal): literal
                case .character(let character): String(character)
                }
            }
            #expect(literals.joined() == field, "\(context)")
            for (token, next) in zip(tokens, tokens.dropFirst() + [.character(" ")]) {
                switch token {
                case .escaped(let literal): #expect(["\\{", "\\}", "\\h"].contains(literal), "\(context)")
                case .lineBreak(let literal): #expect(["\\N", "\\n"].contains(literal), "\(context)")
                case .override(let literal): #expect(literal.first == "{" && literal.last == "}" && literal.filter { $0 == "}" }.count == 1, "\(context)")
                case .character("\\"):
                    #expect(![.character("N"), .character("n"), .character("h"), .character("{"), .character("}")].contains(next), "\(context)")
                case .character: break
                }
            }
        }
    }

    private static let named: [Character: String] = ["&": "amp", "<": "lt", ">": "gt", "\"": "quot", "'": "apos", "\u{A0}": "nbsp"]

    @Test("HTML entities decode to the characters they name")
    func entitiesDecode() {
        let alphabet = Array("&<>\"'\u{A0};#x1aé—字 ")
        var random = SeededGenerator(seed: 0x65_6E74)
        for run in 0..<Self.cases {
            let source = String((0..<Int.random(in: 0...16, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            let encoded = source.map { character -> String in
                if let name = Self.named[character] {
                    return "&" + (Bool.random(using: &random) ? name : name.uppercased()) + ";"
                }
                let scalar = character.unicodeScalars.first!.value
                switch Int.random(in: 0..<6, using: &random) {
                case 0: return "&#\(scalar);"
                case 1: return "&#x" + String(scalar, radix: 16) + ";"
                default: return String(character)
                }
            }.joined()

            #expect(CueMarkup.decodeEntities(encoded) == source, "run \(run): \(encoded.debugDescription)")
        }
    }

    @Test("text that names no entity is left as written")
    func textWithoutEntitiesIsKept() {
        let alphabet = Array("&;#qz 字")
        var random = SeededGenerator(seed: 0x6E_6F65)
        for run in 0..<Self.cases {
            let source = String((0..<Int.random(in: 0...16, using: &random)).map { _ in alphabet.randomElement(using: &random)! })

            #expect(CueMarkup.decodeEntities(source) == source, "run \(run): \(source.debugDescription)")
        }
    }

    @Test("a time written as an ASS timecode reads back to the same hundredth of a second")
    func timecodesReadBack() throws {
        var random = SeededGenerator(seed: 0x74_696D)
        for run in 0..<Self.cases {
            let seconds = Double.random(in: 0...359_999.99, using: &random)

            let read = try #require(CueMarkup.seconds(fromTimestamp: ASSScriptBuilder.timecode(seconds)), "run \(run): \(seconds)")

            #expect(Int((read * 100).rounded()) == Int((seconds * 100).rounded()), "run \(run): \(seconds)")
        }
    }
}
