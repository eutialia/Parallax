import SwiftUI
import ParallaxPlayback

/// The Subtitles menu — a normal pushed screen (slides in like any settings sub-screen) holding the
/// five selection lists. It does NOT draw the preview itself: it just flips `SubtitlePreviewState`
/// on while visible, and the app root fades the floating `SubtitleStageLights` (the dimmed surround
/// + spotlit cue at its true on-screen position) in over everything. So only the subtitle + lights
/// float; the menu stays a regular slide-in.
struct SubtitleSettingsView: View {
    @Environment(SubtitlePreferences.self) private var prefs
    @Environment(SubtitlePreviewState.self) private var preview
    /// Delays the lights so they fade in AFTER the slide-in; cancelled if the user leaves first.
    @State private var activationTask: Task<Void, Never>?

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            SubtitleControlsList(style: prefs.style, onChange: { prefs.update($0) })
        }
        .navigationTitle("Subtitles")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Drive the floating preview: lit while this menu is on screen, gone when it leaves. Activation
        // is delayed ~0.3s so the lights fade in AFTER the menu's slide-in settles; the Task is cancelled
        // on early exit so a quick in-and-out can't strand the lights on. Fade-out stays immediate.
        .onAppear {
            // Cancel any prior pending activation: a second `onAppear` without an intervening
            // `onDisappear` would otherwise orphan the first Task (unreachable, so the exit can't
            // cancel it) and it could flip the lights back on after the menu is gone.
            activationTask?.cancel()
            activationTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                preview.activate()
            }
        }
        .onDisappear {
            activationTask?.cancel()
            activationTask = nil
            preview.deactivate()
        }
    }
}

/// The five subtitle selection lists — Size, Color, Font, Background, Position — plus the
/// overlay-only footnote. A pure view (`SubtitleStyle` in, `onChange` out) so it drops into the
/// preview overlay's floating panel and renders in a `#Preview` with plain `@State`. Each control
/// is the grouped-row idiom (`Button + SettingsRowLabel(accessory: .checkmark)`), the one
/// tappable-selection pattern that's tvOS-focus-safe here (no native Form/Picker).
struct SubtitleControlsList: View {
    let style: SubtitleStyle
    let onChange: (SubtitleStyle) -> Void

    var body: some View {
        #if os(tvOS)
        let spacing = Space.s26
        #else
        let spacing = Space.s22
        #endif
        VStack(spacing: spacing) {
            sizeGroup
            colorGroup
            fontGroup
            backgroundGroup
            positionGroup
            footnote
        }
    }

    // MARK: Groups

    private var sizeGroup: some View {
        SettingsGroup(title: "Size") {
            ForEach(Self.sizeOptions, id: \.self) { scale in
                SettingsListRow(
                    title: Self.sizeLabel(scale),
                    accessory: Self.approxEqual(style.fontScale, scale) ? .checkmark : .none,
                    action: { onChange(style.with { $0.fontScale = scale }) }
                )
            }
        }
    }

    private var colorGroup: some View {
        SettingsGroup(title: "Color") {
            ForEach(Self.colorOptions) { option in
                colorRow(option)
            }
        }
    }

    private var fontGroup: some View {
        SettingsGroup(title: "Font") {
            ForEach(Self.fontOptions, id: \.design) { option in
                SettingsListRow(
                    title: option.name,
                    accessory: style.fontDesign == option.design ? .checkmark : .none,
                    action: { onChange(style.with { $0.fontDesign = option.design }) }
                )
            }
        }
    }

    private var backgroundGroup: some View {
        SettingsGroup(title: "Background") {
            ForEach(Self.backgroundOptions, id: \.value) { option in
                SettingsListRow(
                    title: option.name,
                    accessory: style.background == option.value ? .checkmark : .none,
                    action: { onChange(style.with { $0.background = option.value }) }
                )
            }
        }
    }

    private var positionGroup: some View {
        SettingsGroup(title: "Position") {
            ForEach(Self.positionOptions, id: \.ratio) { option in
                SettingsListRow(
                    title: option.name,
                    accessory: Self.approxEqual(style.verticalOffsetRatio, option.ratio) ? .checkmark : .none,
                    action: { onChange(style.with { $0.verticalOffsetRatio = option.ratio }) }
                )
            }
        }
    }

    private var footnote: some View {
        Text("These settings apply to text subtitles Parallax renders itself. Subtitles built into the video — including styled tracks (anime fan-subs) and image-based ones — keep their original appearance and position.")
            .font(.rowSubtitle)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.headerInset)
            .padding(.top, Space.s8)
    }

    /// Color row: a filled swatch in the glyph column (the only control that needs an arbitrary
    /// fill, so it can't go through `SettingsRowLabel`'s tinted glyph), otherwise the exact
    /// grouped-row layout + tvOS focus platter.
    private func colorRow(_ option: SubtitleColorOption) -> some View {
        let selected = Self.approxEqualColor(style.foreground, option.rgba)
        return Button {
            onChange(style.with { $0.foreground = option.rgba })
        } label: {
            HStack(spacing: Space.s12) {
                Circle()
                    .fill(Color(option.rgba))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.separator, lineWidth: 1))
                    .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)
                Text(option.name)
                    .font(.rowBody)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Spacer(minLength: Space.s12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.rowBody.weight(.semibold))
                        .foregroundStyle(Color.label)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHInset)
            .padding(.vertical, Space.s12)
            .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tvFocusListRow()
            .accessibilityElement(children: .combine)
        }
        .tvListRowButton()
    }

    // MARK: Options

    static let sizeOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    struct SubtitleColorOption: Identifiable {
        let name: String
        let rgba: SubtitleStyle.RGBA
        var id: String { name }
    }
    /// Curated standard caption colors, toned for tone-mapped HDR (matching the off-white default's
    /// rationale) rather than peak primaries. "White" == the canonical default.
    static let colorOptions: [SubtitleColorOption] = [
        .init(name: "White", rgba: SubtitleStyle.standard.foreground),
        .init(name: "Yellow", rgba: .init(red: 1.0, green: 0.93, blue: 0.30)),
        .init(name: "Cyan", rgba: .init(red: 0.45, green: 0.90, blue: 0.96)),
        .init(name: "Green", rgba: .init(red: 0.50, green: 0.92, blue: 0.55)),
    ]

    static let fontOptions: [(name: String, design: SubtitleFontDesign)] = [
        ("System", .sansSerif),
        ("Serif", .serif),
        ("Monospaced", .monospaced),
    ]

    static let backgroundOptions: [(name: String, value: SubtitleBackground)] = [
        ("Outline & Shadow", .outlineShadow),
        ("Opaque Box", .opaqueBox),
    ]

    static let positionOptions: [(name: String, ratio: Double)] = [
        ("Default", 0),
        ("Low", 0.06),
        ("Medium", 0.12),
        ("High", 0.18),
    ]

    // MARK: Helpers

    static func sizeLabel(_ scale: Double) -> String {
        let pct = Int((scale * 100).rounded())
        return scale == 1.0 ? "\(pct)% (Default)" : "\(pct)%"
    }

    static func approxEqual(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

    static func approxEqualColor(_ a: SubtitleStyle.RGBA, _ b: SubtitleStyle.RGBA) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }
}
