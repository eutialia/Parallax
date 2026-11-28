import Foundation
import ParallaxCoreTestSupport
import ParallaxPlayback
import Testing

@Suite("Subtitle style")
struct SubtitleStyleProperties {

    private static let cases = 500

    private enum Edit: CustomStringConvertible {
        case foreground(SubtitleStyle.RGBA)
        case fontScale(Double)
        case fontDesign(SubtitleFontDesign)
        case background(SubtitleBackground)
        case verticalOffsetRatio(Double)

        var description: String {
            switch self {
            case .foreground(let value): "foreground \(value)"
            case .fontScale(let value): "fontScale \(value)"
            case .fontDesign(let value): "fontDesign \(value)"
            case .background(let value): "background \(value)"
            case .verticalOffsetRatio(let value): "verticalOffsetRatio \(value)"
            }
        }

        func apply(to builder: inout SubtitleStyle.Builder) {
            switch self {
            case .foreground(let value): builder.foreground = value
            case .fontScale(let value): builder.fontScale = value
            case .fontDesign(let value): builder.fontDesign = value
            case .background(let value): builder.background = value
            case .verticalOffsetRatio(let value): builder.verticalOffsetRatio = value
            }
        }

        /// `style` with only this field replaced, built field by field.
        func expected(from style: SubtitleStyle) -> SubtitleStyle {
            var foreground = style.foreground, fontScale = style.fontScale, fontDesign = style.fontDesign
            var background = style.background, verticalOffsetRatio = style.verticalOffsetRatio
            switch self {
            case .foreground(let value): foreground = value
            case .fontScale(let value): fontScale = value
            case .fontDesign(let value): fontDesign = value
            case .background(let value): background = value
            case .verticalOffsetRatio(let value): verticalOffsetRatio = value
            }
            return SubtitleStyle(
                foreground: foreground, fontScale: fontScale, fontDesign: fontDesign,
                background: background, verticalOffsetRatio: verticalOffsetRatio)
        }
    }

    private static func color(_ random: inout SeededGenerator) -> SubtitleStyle.RGBA {
        SubtitleStyle.RGBA(
            red: .random(in: 0...1, using: &random), green: .random(in: 0...1, using: &random),
            blue: .random(in: 0...1, using: &random), alpha: .random(in: 0...1, using: &random))
    }

    private static func style(_ random: inout SeededGenerator) -> SubtitleStyle {
        SubtitleStyle(
            foreground: color(&random),
            fontScale: .random(in: 0.5...2, using: &random),
            fontDesign: SubtitleFontDesign.allCases.randomElement(using: &random)!,
            background: SubtitleBackground.allCases.randomElement(using: &random)!,
            verticalOffsetRatio: .random(in: 0...0.5, using: &random))
    }

    private static func edit(_ random: inout SeededGenerator) -> Edit {
        switch Int.random(in: 0..<5, using: &random) {
        case 0: .foreground(color(&random))
        case 1: .fontScale(.random(in: 0.5...2, using: &random))
        case 2: .fontDesign(SubtitleFontDesign.allCases.randomElement(using: &random)!)
        case 3: .background(SubtitleBackground.allCases.randomElement(using: &random)!)
        default: .verticalOffsetRatio(.random(in: 0...0.5, using: &random))
        }
    }

    @Test("an edit to one style field lands, leaves every other field as it was, and an empty edit changes nothing")
    func oneEditChangesOneField() {
        var random = SeededGenerator(seed: 0x73_7479)
        for run in 0..<Self.cases {
            let style = Self.style(&random)
            let edit = Self.edit(&random)

            #expect(style.with { edit.apply(to: &$0) } == edit.expected(from: style), "run \(run): \(edit) on \(style)")
            #expect(style.with { _ in } == style, "run \(run): \(style)")
        }
    }

    @Test("a saved style reads back as it was saved")
    func savedStyleReadsBack() throws {
        var random = SeededGenerator(seed: 0x6A_736F6E)
        for run in 0..<Self.cases {
            let style = Self.style(&random)

            let read = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))

            #expect(read == style, "run \(run)")
        }
    }
}
