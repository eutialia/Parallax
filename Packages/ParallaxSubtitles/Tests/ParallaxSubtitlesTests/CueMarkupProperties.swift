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

    private static func color(_ random: inout SeededGenerator) -> CueColor {
        // A third of the colors can be written with three digits.
        let short = Int.random(in: 0..<3, using: &random) == 0
        func byte() -> UInt8 { short ? UInt8.random(in: 0...15, using: &random) * 17 : .random(in: 0...255, using: &random) }
        return CueColor(red: byte(), green: byte(), blue: byte())
    }

    /// One way a file writes `color`, with the case and spacing files vary.
    private static func spelling(of color: CueColor, _ random: inout SeededGenerator) -> String {
        let hex = String(format: "%02x%02x%02x", color.red, color.green, color.blue)
        let short = hex.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == Array(hex)[$0.offset + 1] }
        var spellings = ["#" + hex, hex, "rgb(\(color.red), \(color.green),\(color.blue))", "rgba(\(color.red),\(color.green),\(color.blue),1)"]
        if short { spellings.append("#" + hex.enumerated().filter { $0.offset % 2 == 0 }.map { String($0.element) }.joined()) }
        spellings += CueColor.named.filter { $0.value == color }.keys.sorted()
        let chosen = spellings.randomElement(using: &random)!
        return Bool.random(using: &random) ? chosen.uppercased() : chosen
    }

    @Test("a color reads as the same three bytes however the file spells it, its override block names them blue first, and anything else is no color")
    func colorsReadBack() throws {
        var random = SeededGenerator(seed: 0x63_6F6C)
        for run in 0..<Self.cases {
            let color = Self.color(&random)
            let spelled = Self.spelling(of: color, &random)

            let read = CueColor(css: " " + spelled + " ")

            #expect(read == color, "run \(run): \(spelled)")
            #expect(color.assOverride == String(format: "{\\c&H%02X%02X%02X&}", color.blue, color.green, color.red), "run \(run)")
        }
        for junk in ["", "#", "#12", "#1234", "12345", "abc", "#gggggg", "rgb(1,2)", "rgb(256,0,0)", "rgb(a,b,c)", "nonsense", "#1234567"] {
            #expect(CueColor(css: junk) == nil, "\(junk)")
        }
    }

    private struct Piece {
        let source: String
        /// The text pieces in order, each with the color it must draw in; nil is the style's.
        let texts: [(text: String, color: CueColor?)]
    }

    /// Text and colored spans nested to any depth, in SRT font tags or WebVTT classes. A span
    /// with no color it can read colors nothing.
    private static func piece(
        under outer: CueColor?, depth: Int, classes: [String: CueColor], _ random: inout SeededGenerator
    ) -> Piece {
        var source = ""
        var texts: [(String, CueColor?)] = []
        for _ in 0..<Int.random(in: 1...3, using: &random) {
            if depth < 3, Int.random(in: 0..<3, using: &random) == 0 {
                let color = Bool.random(using: &random) ? Self.color(&random) : nil
                let useClass = Bool.random(using: &random)
                let open: String
                let inner: CueColor?
                if useClass, let named = classes.keys.sorted().randomElement(using: &random) {
                    let colored = color != nil
                    open = colored ? "<c.plain.\(named)>" : "<c.plain>"
                    inner = colored ? classes[named] : nil
                } else {
                    let attribute = color.map { "color=\"\(Self.spelling(of: $0, &random))\"" } ?? "color=\"nonsense\""
                    open = ["<font face=\"Arial\" \(attribute)>", "<FONT \(attribute) size=3>", "<font \(attribute)>"].randomElement(using: &random)!
                    inner = color
                }
                let nested = piece(under: inner ?? outer, depth: depth + 1, classes: classes, &random)
                source += open + nested.source + (open.lowercased().hasPrefix("<c") ? "</c>" : "</font>")
                texts += nested.texts.map { ($0.text, $0.color) }
            } else {
                let text = String((0..<Int.random(in: 1...4, using: &random)).map { _ in "abc 喵".randomElement(using: &random)! })
                source += text
                texts.append((text, outer))
            }
        }
        return Piece(source: source, texts: texts)
    }

    @Test("every stretch of text draws in the color of the innermost span around it that gives one, and in the style's color when none does")
    func textTakesItsInnermostColor() throws {
        var random = SeededGenerator(seed: 0x73_7061)
        let classes = ["warn": CueColor(red: 255, green: 136, blue: 0), "yellow": CueColor(red: 255, green: 255, blue: 0)]
        for run in 0..<Self.cases {
            let piece = Self.piece(under: nil, depth: 0, classes: classes, &random)

            let tokens = CueMarkup.tokenize(piece.source, options: .init(decodesEntities: false, classColors: classes))

            var current: String?
            var drawn: [(text: String, color: String?)] = []
            for token in tokens {
                switch token {
                case .override(CueColor.assReset): current = nil
                case .override(let block): current = block
                case .text(let text): drawn.append((text, current))
                }
            }
            // Neighboring text under one color is one stretch on both sides.
            func merged(_ stretches: [(text: String, color: String?)]) -> [String] {
                stretches.reduce(into: [(text: String, color: String?)]()) { out, next in
                    if let last = out.last, last.color == next.color {
                        out[out.count - 1].text += next.text
                    } else {
                        out.append(next)
                    }
                }.map { "\($0.color ?? "style") \($0.text)" }
            }
            #expect(merged(drawn) == merged(piece.texts.map { ($0.text, $0.color?.assOverride) }), "run \(run): \(piece.source)")
        }
    }
}
