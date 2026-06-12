import SwiftUI
import ParallaxPlayback
import ParallaxJellyfin

// MARK: - tvOS default-focus plumbing

#if os(tvOS)
extension EnvironmentValues {
    /// The focus scope of the presenting panel, threaded through the environment
    /// so `MenuRow` can hand first focus to the SELECTED row (the system menus'
    /// landing behavior) without every menu view carrying a namespace parameter.
    @Entry var trackMenuFocusScope: Namespace.ID? = nil
}
#endif

/// Marks the selected row as the scope's default focus target on tvOS; inert on
/// touch platforms (no focus engine in the inline panel).
private struct TrackMenuDefaultFocus: ViewModifier {
    let isSelected: Bool
    #if os(tvOS)
    @Environment(\.trackMenuFocusScope) private var scope
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        if let scope {
            content.prefersDefaultFocus(isSelected, in: scope)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Private primitives

private struct MenuHeader: View {
    let systemImage: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.label)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .padding(.horizontal, Space.s14)
        .padding(.top, Space.s8)
        .padding(.bottom, Space.s8)
    }
}

private struct MenuCheckColumn: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.label)
            }
        }
        .frame(width: 22)
    }
}

/// The rows' two text layers: a primary name (who the track is) over an
/// optional detail line (what it's made of) — one vocabulary for audio and
/// subtitles, so the menus can't drift apart again.
private struct MenuRowTitle: View {
    let name: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.label)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
        }
    }
}

/// Trailing attribute badge — reserved for facts that bear on the CHOICE
/// (Forced, SDH, "→ AAC" transcode cost), never for codec/format detail, which
/// belongs on the detail line.
private struct MenuMiniBadge: View {
    let text: String
    var prominent: Bool = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(0.3)
            .foregroundStyle(prominent ? Color.label : Color.secondaryLabel)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MenuFootnote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
                // Wrap, never truncate: an HStack proposes its ideal width and
                // a Text can answer with one ellipsized line.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s14)
        .padding(.top, Space.s8)
    }
}

private struct MenuRow<Trailing: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Trailing

    var body: some View {
        Button(action: action) {
            // tvOS HIG focus contract: the focused row inverts to an opaque white platter.
            // Flipping the row's colorScheme to .light does the content inversion for free —
            // every token inside (label / secondaryLabel / fill) already defines its light
            // value, so checkmarks and badges turn ink-on-white without per-view branches.
            // iOS never focuses, so it keeps the dark-pinned palette from `trackMenuChrome`.
            TVFocusReader { focused in
                content()
                    .padding(.horizontal, Space.s12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Platter as a fading layer (not a style swap, which snaps): it sits
                    // nearer than the selection fill so the crossfade runs over it.
                    .background(
                        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            .fill(.white.opacity(0.97))
                            .opacity(focused ? 1 : 0)
                    )
                    .background(
                        isSelected ? AnyShapeStyle(Color.selectionFill) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    )
                    .environment(\.colorScheme, focused ? .light : .dark)
                    .contentShape(.rect)
                    .animation(.tvFocusChrome, value: focused)
            }
        }
        .tvChipButton()
        .modifier(TrackMenuDefaultFocus(isSelected: isSelected))
    }
}

// MARK: - Public content views

struct AudioTrackMenu: View {
    let tracks: [AudioTrack]
    let selectedID: TrackID?
    let onSelect: (AudioTrack) -> Void

    private var anyTranscode: Bool { tracks.contains { $0.isTranscode } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(
                systemImage: "waveform",
                title: "Audio",
                trailing: "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
            )
            ForEach(tracks, id: \.id) { track in
                MenuRow(isSelected: track.id == selectedID, action: { onSelect(track) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: track.id == selectedID)
                        MenuRowTitle(name: track.displayName, detail: track.detailLabel)
                        Spacer(minLength: Space.s8)
                        // Direct-play rows stay quiet — the badge marks the
                        // exceptional pick, the one that costs a re-encode.
                        if track.isTranscode {
                            MenuMiniBadge(text: "→ \(track.transcodeTarget ?? "AAC")", prominent: true)
                        }
                    }
                }
            }
            if anyTranscode {
                MenuFootnote(text: "Lossless and surround tracks are transcoded to AAC on this device.")
            }
        }
    }
}

struct SubtitleTrackMenu: View {
    let tracks: [SubtitleTrack]
    let selectedID: TrackID?
    let onSelect: (SubtitleTrack?) -> Void

    private var anyExternal: Bool { tracks.contains(where: \.isExternal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(
                systemImage: "captions.bubble",
                title: "Subtitles",
                trailing: "\(tracks.count + 1) options"
            )
            // Off row
            MenuRow(isSelected: selectedID == nil, action: { onSelect(nil) }) {
                HStack(spacing: Space.s12) {
                    MenuCheckColumn(isSelected: selectedID == nil)
                    Text("Off")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.label)
                    Spacer(minLength: 0)
                }
            }
            ForEach(tracks, id: \.id) { track in
                MenuRow(isSelected: track.id == selectedID, action: { onSelect(track) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: track.id == selectedID)
                        MenuRowTitle(name: track.displayName, detail: track.detailLabel)
                        Spacer(minLength: Space.s8)
                        HStack(spacing: 6) {
                            if track.isForced { MenuMiniBadge(text: "Forced", prominent: true) }
                            if track.isSDH { MenuMiniBadge(text: "SDH", prominent: true) }
                        }
                    }
                }
            }
            if anyExternal {
                MenuFootnote(text: "External subtitles are matched by filename or fetched automatically.")
            }
        }
    }
}

struct ChapterMenu: View {
    let chapters: [Chapter]
    let onSelect: (Chapter) -> Void

    var body: some View {
        // LazyVStack (not VStack): a movie can carry 30–60 chapters, and the
        // popover's ScrollView eagerly builds+measures every row of a plain VStack
        // on present — the brief hang when opening the chip. Lazy defers off-screen
        // rows. (Audio/Subtitle/Speed stay plain VStacks: a handful of rows each.)
        LazyVStack(alignment: .leading, spacing: 2) {
            MenuHeader(systemImage: "list.bullet", title: "Chapters", trailing: "\(chapters.count)")
            ForEach(chapters) { chapter in
                MenuRow(isSelected: false, action: { onSelect(chapter) }) {
                    HStack(spacing: Space.s12) {
                        Text("\(chapter.index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.tertiaryLabel)
                            .frame(width: 22)
                        // A name the panel can't fit loops instead of truncating
                        // (panel width is the menu system's, not the longest title's).
                        MarqueeText(
                            text: chapter.name ?? "Chapter \(chapter.index + 1)",
                            font: .callout.weight(.semibold),
                            color: Color.label
                        )
                        Spacer(minLength: Space.s8)
                        Text(Self.timecode(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
            }
        }
    }

    private static func timecode(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct SpeedMenu: View {
    let options: [Double]
    let selected: Double
    let onSelect: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(systemImage: "timer", title: "Speed")
            ForEach(options, id: \.self) { rate in
                MenuRow(isSelected: rate == selected, action: { onSelect(rate) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: rate == selected)
                        Text(Self.label(rate))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.label)
                        Spacer(minLength: Space.s8)
                    }
                }
            }
        }
    }

    /// Shared "1.5×" formatter — also used by the speed chip label so the chip and
    /// the menu can't drift.
    static func label(_ rate: Double) -> String {
        let s = String(format: rate == rate.rounded() ? "%.0f" : "%g", rate)
        return s + "×"
    }
}

// MARK: - Previews

#Preview("Audio + subtitles", traits: .sizeThatFitsLayout) {
    VStack(spacing: 24) {
        AudioTrackMenu(
            tracks: [
                AudioTrack(
                    id: .jellyfinStream(1),
                    displayName: "English",
                    languageCode: "eng",
                    detailLabel: "TrueHD · 7.1",
                    isTranscode: true,
                    transcodeTarget: "AAC"
                ),
                AudioTrack(
                    id: .jellyfinStream(2),
                    displayName: "English",
                    languageCode: "eng",
                    detailLabel: "AAC · Stereo",
                    isTranscode: false,
                    transcodeTarget: nil
                ),
                AudioTrack(
                    id: .jellyfinStream(3),
                    displayName: "Director's Commentary",
                    languageCode: "eng",
                    detailLabel: "Dolby Digital · 5.1",
                    isTranscode: false,
                    transcodeTarget: nil
                ),
            ],
            selectedID: .jellyfinStream(1),
            onSelect: { _ in }
        )
        SubtitleTrackMenu(
            tracks: [
                SubtitleTrack(
                    id: .jellyfinStream(4),
                    displayName: "English",
                    languageCode: "eng",
                    isForced: false,
                    detailLabel: "SRT · External",
                    isExternal: true,
                    isSDH: true
                ),
                SubtitleTrack(
                    id: .jellyfinStream(5),
                    displayName: "Spanish",
                    languageCode: "spa",
                    isForced: true,
                    detailLabel: "ASS · Embedded",
                    isExternal: false,
                    isSDH: false
                ),
            ],
            selectedID: .jellyfinStream(4),
            onSelect: { _ in }
        )
    }
    .padding()
    // Mirrors the live panel width (PlayerControlsView.panelWidth) so this
    // preview stays an honest specimen of what ships.
    .frame(width: 320)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

#Preview("Speed + chapters", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 24) {
        SpeedMenu(options: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0], selected: 1.0, onSelect: { _ in })
            .frame(width: 200)
        ChapterMenu(
            chapters: [
                Chapter(index: 0, name: "Opening", start: .seconds(0)),
                Chapter(index: 1, name: "A Chapter Title So Long It Cannot Possibly Fit The Panel",
                        start: .seconds(412)),
                Chapter(index: 2, name: nil, start: .seconds(1815)),
                Chapter(index: 3, name: "Finale", start: .seconds(5403)),
            ],
            onSelect: { _ in }
        )
        .frame(width: 360)
    }
    .padding()
    .background(Color.background)
    .preferredColorScheme(.dark)
    // Deterministic snapshot: the marquee otherwise loops forever and the
    // preview agent never reaches quiescence (UpdateTimedOutError). This pins
    // the truncation branch; the live loop is a device/simulator check.
    .environment(\.marqueeEnabled, false)
}
