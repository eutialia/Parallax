#if DEBUG
import SwiftUI
import Testing
import UIKit
import ParallaxPlayback
@testable import Parallax

/// Headless pixel proof for the subtitle-settings v1 work — renders the real `SubtitleCueText`, the
/// controls list, and the floating `SubtitleStageLights` with `ImageRenderer` (no Xcode needed) and
/// dumps PNGs to the host `/tmp` (the iOS Simulator shares the Mac filesystem). Eyes-on questions:
///  1. CJK serif: does SwiftUI `.serif` resolve to a serif CJK face or fall back to sans? (spec gate)
///  2. Both legibility backings stay readable over busy light content (outline ring vs opaque box).
///  3. The "lights" dim the menu and spotlight the cue at its true playback position.
///
/// NOTE: `ImageRenderer` can't snapshot a `ScrollView`, so the menu stand-in here is the plain
/// `SubtitleControlsList` (no scroll); the integrated scrolling menu + lights is a device check.
@MainActor
struct SubtitleRenderTests {

    @Test("CJK × font design — serif fallback check → /tmp/subtitle_cjk_fonts.png")
    func renderCJKFonts() throws {
        let designs: [(String, SubtitleFontDesign)] = [
            ("System (sans)", .sansSerif), ("Serif", .serif), ("Monospaced", .monospaced),
        ]
        let samples = ["EN — Subtitle Aa Bb 0123", "中文字幕测试 — 永遠", "日本語の字幕 — 永遠", "한국어 자막 — 영원"]
        let view = ZStack {
            Color(white: 0.16)
            VStack(spacing: 22) {
                ForEach(designs, id: \.0) { name, design in
                    VStack(spacing: 6) {
                        Text(name).font(.caption).foregroundStyle(.white.opacity(0.6))
                        ForEach(samples, id: \.self) { s in
                            SubtitleCueText(s, fontSize: 30, style: .standard.with { $0.fontDesign = design })
                        }
                    }
                }
            }
            .padding(28)
        }
        try dump(view, width: 900, height: 900, name: "subtitle_cjk_fonts")
    }

    @Test("Cue legibility — outline vs box, colors → /tmp/subtitle_cue_legibility.png")
    func renderLegibility() throws {
        let yellow = SubtitleStyle.RGBA(red: 1.0, green: 0.93, blue: 0.30)
        let cyan = SubtitleStyle.RGBA(red: 0.45, green: 0.90, blue: 0.96)
        let view = ZStack {
            LinearGradient(colors: [.white, Color(white: 0.82), .yellow.opacity(0.5), Color(white: 0.25)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 30) {
                SubtitleCueText("Outline — The quick brown fox", fontSize: 30, style: .standard)
                SubtitleCueText("Opaque box — over busy light content", fontSize: 30,
                                style: .standard.with { $0.background = .opaqueBox })
                SubtitleCueText("Yellow, larger", fontSize: 45,
                                style: .standard.with { $0.foreground = yellow })
                SubtitleCueText("Cyan serif box", fontSize: 30,
                                style: .standard.with { $0.foreground = cyan; $0.background = .opaqueBox; $0.fontDesign = .serif })
            }
            .padding(28)
        }
        try dump(view, width: 900, height: 720, name: "subtitle_cue_legibility")
    }

    @Test("Stage lights over menu — iPhone portrait → /tmp/subtitle_lights_portrait.png")
    func renderLightsPortrait() throws {
        try renderLights(width: 393, height: 852, scheme: .light, name: "subtitle_lights_portrait")
    }

    @Test("Stage lights over menu — iPhone landscape (dark) → /tmp/subtitle_lights_landscape.png")
    func renderLightsLandscape() throws {
        try renderLights(width: 852, height: 393, scheme: .dark, name: "subtitle_lights_landscape")
    }

    /// Composites the floating `SubtitleStageLights` over a SHORT menu stand-in (a couple of groups,
    /// so it fits the top and the cue is visible at the bottom), so the dim + spotlight + real-position
    /// cue read against actual control content. The live menu is a ScrollView (can't be snapshotted).
    private func renderLights(width: CGFloat, height: CGFloat, scheme: ColorScheme, name: String) throws {
        let style = SubtitleStyle.standard.with {
            $0.foreground = .init(red: 1.0, green: 0.93, blue: 0.30)
            $0.background = .opaqueBox
            $0.fontScale = 1.25
            $0.verticalOffsetRatio = 0.06
        }
        let menu = VStack(spacing: 22) {
            SettingsGroup(title: "Size") {
                SettingsListRow(title: "100% (Default)", action: {})
                SettingsListRow(title: "125%", accessory: .checkmark, action: {})
                SettingsListRow(title: "150%", action: {})
            }
            SettingsGroup(title: "Color") {
                SettingsListRow(title: "White", action: {})
                SettingsListRow(title: "Yellow", accessory: .checkmark, action: {})
            }
        }
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
        .padding(.horizontal, 4)

        let view = ZStack {
            Color.background
            menu
            SubtitleStageLights(style: style)
        }
        .environment(\.appIdiom, .compact)
        .environment(\.colorScheme, scheme)
        try dump(view, width: width, height: height, name: name)
    }

    @Test("Controls legibility over dark backdrop → /tmp/subtitle_controls_dark.png")
    func renderControlsDark() throws {
        let style = SubtitleStyle.standard.with {
            $0.foreground = .init(red: 1.0, green: 0.93, blue: 0.30)
            $0.background = .opaqueBox
            $0.fontScale = 1.25
        }
        let view = ZStack {
            LinearGradient(colors: [Color(.sRGB, red: 0.09, green: 0.10, blue: 0.13, opacity: 1),
                                    Color(.sRGB, red: 0.05, green: 0.05, blue: 0.06, opacity: 1)],
                           startPoint: .top, endPoint: .bottom)
            SubtitleControlsList(style: style, onChange: { _ in })
                .frame(maxWidth: 540)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
        }
        .environment(\.appIdiom, .compact)
        .environment(\.colorScheme, .dark)
        try dump(view, width: 560, height: 1360, name: "subtitle_controls_dark")
    }

    @Test("CJK serif candidates — availability + cascade → /tmp/subtitle_cjk_serif.{png,txt}")
    func renderCJKSerifCandidates() throws {
        let size: CGFloat = 32

        // 1. What serif-ish CJK families actually ship on iOS? Dump the list for the record.
        let keywords = ["Song", "Mincho", "Myung", "Ming", "Sung", "Kai", "Yuanti", "Heiti", "PingFang", "Hiragino"]
        var report = "CJK-candidate font families on iOS sim:\n"
        for fam in UIFont.familyNames.sorted() where keywords.contains(where: { fam.localizedCaseInsensitiveContains($0) }) {
            report += "• \(fam): \(UIFont.fontNames(forFamilyName: fam).joined(separator: ", "))\n"
        }
        try? report.write(toFile: "/tmp/subtitle_cjk_serif.txt", atomically: true, encoding: .utf8)

        // 2. A cascade "Serif": New York (Latin) + named CJK serif faces as fallback.
        let cascadeFont: Font = {
            let base = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
                ?? UIFont.systemFont(ofSize: size).fontDescriptor
            let fallback = ["Songti SC", "Songti TC", "Hiragino Mincho ProN", "AppleMyungjo"]
                .map { UIFontDescriptor(fontAttributes: [.name: $0]) }
            return Font(UIFont(descriptor: base.addingAttributes([.cascadeList: fallback]), size: size))
        }()

        func custom(_ name: String) -> Font { Font.custom(name, size: size) }
        let samples = ["EN Serif Aa Rr", "中文字幕 永遠", "日本語字幕 永遠", "한국어 자막 영원"]
        let cols: [(String, Font)] = [
            ("System (sans)", .system(size: size)),
            (".serif design", .system(size: size, design: .serif)),
            ("Songti SC", custom("Songti SC")),
            ("Hiragino Mincho", custom("Hiragino Mincho ProN")),
            ("Cascade serif", cascadeFont),
        ]
        let view = ZStack {
            Color(white: 0.15)
            HStack(alignment: .top, spacing: 22) {
                ForEach(cols, id: \.0) { name, f in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(name).font(.caption2).foregroundStyle(.white.opacity(0.55))
                        ForEach(samples, id: \.self) { s in
                            Text(s).font(f).foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(26)
        }
        try dump(view, width: 1320, height: 380, name: "subtitle_cjk_serif")
    }

    private func dump(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "ImageRenderer produced no image")
        let png = try #require(image.pngData())
        #expect(png.count > 1_000, "render suspiciously small")
        try? png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
#endif
