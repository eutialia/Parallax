import Foundation

/// A color that a cue's markup gives its text.
struct CueColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// The `\c` block for this color. ASS writes a color blue first.
    var assOverride: String {
        String(format: "{\\c&H%02X%02X%02X&}", blue, green, red)
    }

    /// Back to the color of the line's style.
    static let assReset = "{\\c}"

    /// Reads a color as SRT font tags and WebVTT style sheets write one: a name, `#rgb`,
    /// `#rrggbb`, six hex digits with no `#`, or `rgb(r, g, b)`. Nil for anything else.
    init?(css raw: some StringProtocol) {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = Self.named[text] {
            self = named
        } else if text.hasPrefix("rgb") {
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
            let parts = text[text.index(after: open)..<close].split(separator: ",")
                .map { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 || parts.count == 4, let red = parts[0], let green = parts[1], let blue = parts[2] else {
                return nil
            }
            self.init(red: red, green: green, blue: blue)
        } else {
            let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
            guard digits.allSatisfy(\.isHexDigit), digits.count == 6 || (digits.count == 3 && text.hasPrefix("#")) else {
                return nil
            }
            let wide = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
            guard let value = UInt32(wide, radix: 16) else { return nil }
            self.init(red: UInt8(value >> 16), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
        }
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The sixteen HTML color names and orange.
    static let named: [String: CueColor] = [
        "black": CueColor(red: 0, green: 0, blue: 0), "silver": CueColor(red: 192, green: 192, blue: 192),
        "gray": CueColor(red: 128, green: 128, blue: 128), "grey": CueColor(red: 128, green: 128, blue: 128),
        "white": CueColor(red: 255, green: 255, blue: 255), "maroon": CueColor(red: 128, green: 0, blue: 0),
        "red": CueColor(red: 255, green: 0, blue: 0), "purple": CueColor(red: 128, green: 0, blue: 128),
        "fuchsia": CueColor(red: 255, green: 0, blue: 255), "magenta": CueColor(red: 255, green: 0, blue: 255),
        "green": CueColor(red: 0, green: 128, blue: 0), "lime": CueColor(red: 0, green: 255, blue: 0),
        "olive": CueColor(red: 128, green: 128, blue: 0), "yellow": CueColor(red: 255, green: 255, blue: 0),
        "navy": CueColor(red: 0, green: 0, blue: 128), "blue": CueColor(red: 0, green: 0, blue: 255),
        "teal": CueColor(red: 0, green: 128, blue: 128), "aqua": CueColor(red: 0, green: 255, blue: 255),
        "cyan": CueColor(red: 0, green: 255, blue: 255), "orange": CueColor(red: 255, green: 165, blue: 0),
    ]

    /// The classes WebVTT colors text by with no style sheet.
    static let webVTTClasses: [String: CueColor] = named.filter {
        ["white", "lime", "cyan", "red", "yellow", "magenta", "blue", "black"].contains($0.key)
    }

    /// The colors a WebVTT STYLE block gives to classes: the `color` of each rule whose
    /// selector is `::cue(.name)` or `::cue(c.name)`.
    static func classColors(inStyleBlock block: some StringProtocol) -> [String: CueColor] {
        var colors: [String: CueColor] = [:]
        var rest = Substring(block)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let declarations = rest[rest.index(after: open)..<close].split(separator: ";")
            let color = declarations.lazy.compactMap { declaration -> CueColor? in
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "color" else {
                    return nil
                }
                return CueColor(css: pair[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }.first
            if let color {
                for selector in rest[..<open].split(separator: ",") {
                    let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("::cue("), trimmed.hasSuffix(")") else { continue }
                    let inner = trimmed.dropFirst("::cue(".count).dropLast().trimmingCharacters(in: .whitespaces)
                    let name = inner.hasPrefix("c.") ? inner.dropFirst(2) : inner.hasPrefix(".") ? inner.dropFirst(1) : ""
                    guard !name.isEmpty, !name.contains(where: { $0 == "." || $0 == " " || $0 == ":" }) else { continue }
                    colors[String(name)] = color
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        return colors
    }
}
