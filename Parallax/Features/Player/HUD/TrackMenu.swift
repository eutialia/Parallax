import SwiftUI
import ParallaxPlayback
import ParallaxJellyfin
import ParallaxCore

// MARK: - tvOS row-focus plumbing

#if os(tvOS)
extension EnvironmentValues {
    /// The presenting panel's row-focus binding, threaded through the environment so
    /// every `MenuRow` can register against it without carrying a parameter. The panel
    /// drives it PROGRAMMATICALLY to land first focus on the SELECTED row (the system
    /// menus' behavior): `prefersDefaultFocus` was a no-op here — it only applies when
    /// no view has focus, and opening a panel RELOCATES focus (the chip just disabled),
    /// which left first focus wherever the engine's geometry put it.
    @Entry var trackMenuRowFocus: FocusState<AnyHashable?>.Binding? = nil
}
#endif

/// Binds a row to the panel's focus state under its key; inert on touch platforms
/// (no focus engine in the inline panel).
private struct TrackMenuRowFocus: ViewModifier {
    let key: AnyHashable
    #if os(tvOS)
    @Environment(\.trackMenuRowFocus) private var binding
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        if let binding {
            content.focused(binding, equals: key)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Fixed row metrics that can't ride the semantic text styles: tvOS renders those
/// ~1.5× (10-foot UI), so the iOS-tuned check column and badge box clipped their
/// own glyphs there (the "funky" audio badge).
private enum MenuMetrics {
    /// Selected / focused row platter radius, CONCENTRIC with the panel: `Radius.panel` minus
    /// `trackMenuChrome`'s `Space.s8` content inset. At the first/last row the platter sits in the
    /// panel's rounded corner, so its corner has to curve parallel to the panel's — a smaller radius
    /// balls up a wider gap at the diagonal (the corners look mismatched).
    static let platterRadius = Radius.panel - Space.s8
    #if os(tvOS)
    static let checkColumn: CGFloat = 34
    static let badgeRadius: CGFloat = 9
    static let badgePadX: CGFloat = 10
    static let badgePadY: CGFloat = 5
    #else
    static let checkColumn: CGFloat = 22
    static let badgeRadius: CGFloat = 6
    static let badgePadX: CGFloat = 7
    static let badgePadY: CGFloat = 4
    #endif
}

// MARK: - Private primitives

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
        .frame(width: MenuMetrics.checkColumn)
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
            .padding(.horizontal, MenuMetrics.badgePadX)
            .padding(.vertical, MenuMetrics.badgePadY)
            .background(Color.playerTrackBadgeFill, in: RoundedRectangle(cornerRadius: MenuMetrics.badgeRadius,
                                                                         style: .continuous))
    }
}

private struct MenuFootnote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s8) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(Color.tertiaryLabel)
            Text(text)
                .font(.caption2)
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
    /// The row's identity in the panel's focus state — what the panel assigns to land
    /// first focus here, and what `defaultFocus` re-targets on later evaluations.
    let focusKey: AnyHashable
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
                        RoundedRectangle(cornerRadius: MenuMetrics.platterRadius, style: .continuous)
                            .fill(.white)
                            .opacity(focused ? 1 : 0)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: MenuMetrics.platterRadius, style: .continuous)
                            .fill(isSelected ? Color.playerTrackSelectionFill : .clear)
                    )
                    .environment(\.colorScheme, focused ? .light : .dark)
                    .contentShape(.rect)
                    .animation(.tvFocusChrome, value: focused)
            }
        }
        .tvMenuRowButton()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(TrackMenuRowFocus(key: focusKey))
    }
}

// MARK: - Public content views

struct AudioTrackMenu: View {
    let tracks: [AudioTrack]
    let selectedID: TrackID?
    let onSelect: (AudioTrack) -> Void

    private var anyTranscode: Bool { tracks.contains { $0.isTranscode } }

    /// First-focus row key for the presenting panel (tvOS): the selected track,
    /// falling back to the first row.
    static func defaultFocusKey(tracks: [AudioTrack], selectedID: TrackID?) -> AnyHashable? {
        (tracks.first { $0.id == selectedID } ?? tracks.first)?.id
    }

    var body: some View {
        ForEach(tracks, id: \.id) { track in
            MenuRow(focusKey: track.id, isSelected: track.id == selectedID,
                    action: { onSelect(track) }) {
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

struct SubtitleTrackMenu: View {
    let tracks: [SubtitleTrack]
    let selectedID: TrackID?
    let onSelect: (SubtitleTrack?) -> Void

    private var anyExternal: Bool { tracks.contains(where: \.isExternal) }
    private var anyBurnedIn: Bool { tracks.contains(where: \.isBurnedIn) }

    /// The Off row's focus key — it has no `TrackID`.
    static let offFocusKey: AnyHashable = "subtitles-off"

    /// First-focus row key for the presenting panel (tvOS): the selected track, or Off.
    static func defaultFocusKey(tracks: [SubtitleTrack], selectedID: TrackID?) -> AnyHashable {
        tracks.first { $0.id == selectedID }.map { AnyHashable($0.id) } ?? offFocusKey
    }

    var body: some View {
        // Off row
        MenuRow(focusKey: Self.offFocusKey, isSelected: selectedID == nil,
                action: { onSelect(nil) }) {
            HStack(spacing: Space.s12) {
                MenuCheckColumn(isSelected: selectedID == nil)
                Text("Off")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.label)
                Spacer(minLength: 0)
            }
        }
        ForEach(tracks, id: \.id) { track in
            MenuRow(focusKey: track.id, isSelected: track.id == selectedID,
                    action: { onSelect(track) }) {
                HStack(spacing: Space.s12) {
                    MenuCheckColumn(isSelected: track.id == selectedID)
                    MenuRowTitle(name: track.displayName, detail: track.detailLabel)
                    Spacer(minLength: Space.s8)
                    HStack(spacing: 6) {
                        if track.isForced { MenuMiniBadge(text: "Forced", prominent: true) }
                        if track.isSDH { MenuMiniBadge(text: "SDH", prominent: true) }
                        // Quiet by default — the badge marks the exceptional pick,
                        // the one that costs a full re-encode (mirrors the audio
                        // menu's "→ AAC" transcode badge).
                        if track.isBurnedIn { MenuMiniBadge(text: "Burn-in", prominent: true) }
                    }
                }
            }
        }
        if anyExternal {
            MenuFootnote(text: "External subtitles are matched by filename or fetched automatically.")
        }
        if anyBurnedIn {
            MenuFootnote(text: "Image subtitles are burned into the video, which re-encodes the stream.")
        }
    }
}

struct ChapterMenu: View {
    let chapters: [Chapter]
    let onSelect: (Chapter) -> Void

    /// First-focus row key for the presenting panel (tvOS): no row is "selected",
    /// so land on the chapter containing the playhead.
    static func defaultFocusKey(chapters: [Chapter], atSeconds seconds: Double) -> AnyHashable? {
        (chapters.last { $0.start <= .seconds(seconds) } ?? chapters.first)?.id
    }

    var body: some View {
        // The outer `LazyVStack` in `trackMenuChrome` realizes these rows lazily, so a 30–60 chapter
        // movie defers off-screen rows (no build+measure hang on present).
        ForEach(chapters) { chapter in
            MenuRow(focusKey: chapter.id, isSelected: false, action: { onSelect(chapter) }) {
                HStack(spacing: Space.s12) {
                    Text("\(chapter.index + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.tertiaryLabel)
                        .frame(width: MenuMetrics.checkColumn)
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

    private static func timecode(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let whole = Duration.seconds(total)
        return total >= 3600
            ? whole.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 0)))
            : whole.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 0)))
    }
}

struct SpeedMenu: View {
    let options: [Double]
    let selected: Double
    let onSelect: (Double) -> Void

    /// First-focus row key for the presenting panel (tvOS): the active rate.
    static func defaultFocusKey(options: [Double], selected: Double) -> AnyHashable? {
        options.contains(selected) ? selected : options.first
    }

    var body: some View {
        ForEach(options, id: \.self) { rate in
            MenuRow(focusKey: rate, isSelected: rate == selected, action: { onSelect(rate) }) {
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

    /// Shared "1.5×" formatter — also used by the speed chip label so the chip and
    /// the menu can't drift.
    static func label(_ rate: Double) -> String {
        let s = rate.formatted(.number.precision(.fractionLength(0...2)))
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
                SubtitleTrack(
                    id: .jellyfinStream(6),
                    displayName: "German",
                    languageCode: "deu",
                    isForced: false,
                    detailLabel: "PGS",
                    isExternal: false,
                    isSDH: false,
                    isBurnedIn: true
                ),
            ],
            selectedID: .jellyfinStream(4),
            onSelect: { _ in }
        )
    }
    .padding()
    // Mirrors the live panel width (PlayerControlsView.panelWidth): tvOS 320×1.5, iPad 320,
    // iPhone 320×0.8 = 256. Pinned to the iPhone width here — the tightest case, where the
    // audio row's name + detail + "→ AAC" badge has the least room — so the specimen proves
    // the compact phone panel doesn't truncate.
    #if os(tvOS)
    .frame(width: 480)
    #else
    .frame(width: 256)
    #endif
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

/// A menu in its real panel chrome — mirrors `PlayerControlsView.trackMenuChrome` (ScrollView +
/// `LazyVStack` + `Space.s8` inset + `Radius.panel` glass, clipped, no scroll indicator). Renders on
/// iOS to confirm there's no in-panel title and the first row sits cleanly under the panel's rounded
/// top (rows clip to the corners when scrolled). A short frame forces overflow so the bottom clip
/// shows too.
#Preview("Track panel · no header", traits: .sizeThatFitsLayout) {
    let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
    return ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
            AudioTrackMenu(
                tracks: [
                    AudioTrack(id: .jellyfinStream(1), displayName: "English", languageCode: "eng",
                               detailLabel: "TrueHD · 7.1", isTranscode: true, transcodeTarget: "AAC"),
                    AudioTrack(id: .jellyfinStream(2), displayName: "English", languageCode: "eng",
                               detailLabel: "AAC · Stereo", isTranscode: false, transcodeTarget: nil),
                    AudioTrack(id: .jellyfinStream(3), displayName: "Commentary", languageCode: "eng",
                               detailLabel: "AC3 · 5.1", isTranscode: false, transcodeTarget: nil),
                ],
                selectedID: .jellyfinStream(1),
                onSelect: { _ in }
            )
        }
        .padding(Space.s8)
    }
    .scrollIndicators(.hidden)
    .frame(width: 320, height: 200)
    .clipShape(shape)
    .glassEffect(.regular, in: shape)
    .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
