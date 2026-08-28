import SwiftUI
import ParallaxPlayback
import ParallaxJellyfin
import ParallaxCore

/// A track-menu row's identity — ONE value that serves as both the scroll-target id
/// (`.id(_:)` under `TrackMenuPanel`'s `scrollTargetLayout`) and the tvOS focus key, so
/// the row a panel scrolls to and the row it focuses can't drift apart.
///
/// A dedicated enum rather than `AnyHashable`: `ScrollPosition.scrollTo(id:)` requires
/// `Sendable`, and a typeless box can't vouch for its payload — the same constraint that
/// produced `SMBBrowseScrollAnchor`. It also collapses four key schemes (a `TrackID`, a
/// `Double` rate, a chapter index, and the Off sentinel) into one id type, which is what
/// `scrollTargetLayout` needs to resolve a row across menus.
// nonisolated: `ScrollPosition` hashes this off the main actor, and the resolver tests
// build values outside it — the app target's default-MainActor mode would otherwise
// isolate the conformance.
nonisolated enum TrackMenuRowID: Hashable, Sendable {
    /// The subtitle menu's "Off" row — it has no `TrackID`.
    case subtitlesOff
    case track(TrackID)
    case rate(Double)
    case chapter(Chapter.ID)
}

// MARK: - tvOS row-focus plumbing

#if os(tvOS)
extension EnvironmentValues {
    /// The presenting panel's row-focus binding, threaded through the environment so
    /// every `MenuRow` can register against it without carrying a parameter. The panel
    /// drives it PROGRAMMATICALLY to land first focus on the SELECTED row (the system
    /// menus' behavior): `prefersDefaultFocus` was a no-op here — it only applies when
    /// no view has focus, and opening a panel RELOCATES focus (the chip just disabled),
    /// which left first focus wherever the engine's geometry put it.
    @Entry var trackMenuRowFocus: FocusState<TrackMenuRowID?>.Binding? = nil
}
#endif

/// Binds a row to the panel's focus state under its key; inert on touch platforms
/// (no focus engine in the inline panel).
private struct TrackMenuRowFocus: ViewModifier {
    let key: TrackMenuRowID
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
    /// `TrackMenuPanel`'s `Space.s8` content inset. At the first/last row the platter sits in the
    /// panel's rounded corner, so its corner has to curve parallel to the panel's — a smaller radius
    /// balls up a wider gap at the diagonal (the corners look mismatched).
    static let platterRadius = Radius.panel - Space.s8
    /// Dim for a row that can't be picked (a codec the engine has no decoder for). The
    /// `.plain`/quiet button styles don't dim their own label, so the row draws it.
    static let unavailableOpacity: Double = 0.4
    /// Indeterminate spinner size for the check column. tvOS renders the column 34pt for
    /// the 10-foot UI, so the smallest control size would be a speck in it.
    #if os(tvOS)
    static let spinnerControlSize: ControlSize = .regular
    static let checkColumn: CGFloat = 34
    static let badgeRadius: CGFloat = 9
    static let badgePadX: CGFloat = 10
    static let badgePadY: CGFloat = 5
    #else
    static let spinnerControlSize: ControlSize = .small
    static let checkColumn: CGFloat = 22
    static let badgeRadius: CGFloat = 6
    static let badgePadX: CGFloat = 7
    static let badgePadY: CGFloat = 4
    #endif
}

// MARK: - Private primitives

private struct MenuCheckColumn: View {
    let isSelected: Bool
    /// The row's sidecar is being fetched: the column spins instead of ticking. A cold
    /// embedded Jellyfin stream is extracted server-side on first request, which can take
    /// seconds.
    var isLoading: Bool = false

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    // Sized off the column, not `.controlSize(.small)`: tvOS bumps the
                    // column 22→34pt for the 10-foot UI, and a hardcoded small spinner
                    // reads as a speck there — the exact metric drift `MenuMetrics` exists
                    // to prevent.
                    .controlSize(MenuMetrics.spinnerControlSize)
                    // An unlabeled indeterminate ProgressView contributes no text, so the
                    // row's merged VoiceOver label would be byte-identical loading or not.
                    .accessibilityLabel("Loading")
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.label)
                    .transition(.opacity)
            }
        }
        .frame(width: MenuMetrics.checkColumn)
        // Spinner→checkmark is a completion, not a glitch: crossfade it, like every
        // other state change in this row.
        .animation(.default, value: isLoading)
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
    /// The row's one identity: the panel's scroll target (`.id` below, under its
    /// `scrollTargetLayout`) AND — on tvOS — its focus key, what the panel assigns to
    /// land first focus here and what `defaultFocus` re-targets later.
    let rowID: TrackMenuRowID
    let isSelected: Bool
    /// The row is shown but can't be picked. On tvOS this also drops it out of the focus
    /// order, which is the honest 10-foot equivalent of a greyed-out row.
    var isUnavailable: Bool = false
    let action: () -> Void
    @ViewBuilder let content: () -> Trailing

    var body: some View {
        Button(action: action) {
            // tvOS HIG focus contract: the focused row inverts to an opaque white platter.
            // Flipping the row's colorScheme to .light does the content inversion for free —
            // every token inside (label / secondaryLabel / fill) already defines its light
            // value, so checkmarks and badges turn ink-on-white without per-view branches.
            // iOS never focuses, so it keeps the dark-pinned palette from `TrackMenuPanel`.
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
                    .opacity(isUnavailable ? MenuMetrics.unavailableOpacity : 1)
                    .animation(.tvFocusChrome, value: focused)
            }
        }
        .tvMenuRowButton()
        .disabled(isUnavailable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Outermost, past the focus modifier: `TrackMenuRowFocus` wraps the row in an
        // `if let binding` branch, and an `.id` applied inside that branch is attached to
        // whichever arm the branch produced — the scroll target has to sit on the row the
        // `scrollTargetLayout` actually sees.
        .modifier(TrackMenuRowFocus(key: rowID))
        .id(rowID)
    }
}

// MARK: - Public content views

struct AudioTrackMenu: View {
    let tracks: [AudioTrack]
    let selectedID: TrackID?
    let onSelect: (AudioTrack) -> Void

    private var anyTranscode: Bool { tracks.contains { $0.isTranscode } }
    private var anyUnsupported: Bool { tracks.contains(where: \.isUnsupported) }

    /// The row the panel opens scrolled to: the selected track, falling back to the
    /// first. Unfiltered — a track the engine can't decode is still shown, so it still
    /// gets to lead the list when it's the one selected.
    nonisolated static func leadingRowID(tracks: [AudioTrack], selectedID: TrackID?) -> TrackMenuRowID? {
        (tracks.first { $0.id == selectedID } ?? tracks.first).map { .track($0.id) }
    }

    /// First-focus row for the presenting panel (tvOS): the same pick over the SUPPORTED
    /// rows only — the unsupported ones are `.disabled`, so the focus engine can't land
    /// there. The one menu whose focus target can differ from its scroll target.
    nonisolated static func focusableLeadingRowID(tracks: [AudioTrack], selectedID: TrackID?) -> TrackMenuRowID? {
        leadingRowID(tracks: tracks.filter { !$0.isUnsupported }, selectedID: selectedID)
    }

    /// The detail line says what the track is made of; for a codec the engine can't
    /// decode it also has to say so, because the row's dimming alone doesn't explain why.
    ///
    /// The marker leads: the line is one truncating row, and on the narrow phone panel
    /// "TrueHD · 7.1 · Not supported" loses exactly the words that carry the meaning.
    /// Codec detail is the safer thing to drop off the end.
    static func detail(for track: AudioTrack) -> String? {
        guard track.isUnsupported else { return track.detailLabel }
        guard let detail = track.detailLabel else { return "Not supported" }
        return "Not supported · \(detail)"
    }

    var body: some View {
        ForEach(tracks, id: \.id) { track in
            MenuRow(rowID: .track(track.id), isSelected: track.id == selectedID,
                    isUnavailable: track.isUnsupported,
                    action: { onSelect(track) }) {
                HStack(spacing: Space.s12) {
                    MenuCheckColumn(isSelected: track.id == selectedID)
                    MenuRowTitle(name: track.displayName, detail: Self.detail(for: track))
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
        if anyUnsupported {
            MenuFootnote(text: "Some tracks use a format this device can't decode.")
        }
    }
}

struct SubtitleTrackMenu: View {
    let tracks: [SubtitleTrack]
    let selectedID: TrackID?
    /// The track whose sidecar is being fetched — its check column spins instead of
    /// ticking. A cold embedded stream is extracted server-side on first request.
    var loadingID: TrackID? = nil
    let onSelect: (SubtitleTrack?) -> Void

    private var anyExternal: Bool { tracks.contains(where: \.isExternal) }
    private var anyBurnedIn: Bool { tracks.contains(where: \.isBurnedIn) }

    /// The row the panel opens scrolled to — and, on tvOS, focuses: the selected track,
    /// or the Off row. Every row here is pickable, so scroll and focus can't diverge
    /// (only the audio menu needs a second, filtered resolver).
    nonisolated static func leadingRowID(tracks: [SubtitleTrack], selectedID: TrackID?) -> TrackMenuRowID {
        tracks.first { $0.id == selectedID }.map { .track($0.id) } ?? .subtitlesOff
    }

    var body: some View {
        // Off row
        MenuRow(rowID: .subtitlesOff, isSelected: selectedID == nil,
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
            MenuRow(rowID: .track(track.id), isSelected: track.id == selectedID,
                    action: { onSelect(track) }) {
                HStack(spacing: Space.s12) {
                    MenuCheckColumn(
                        isSelected: track.id == selectedID,
                        isLoading: track.id == loadingID
                    )
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

    /// The row the panel opens scrolled to (and focuses on tvOS): no row is "selected",
    /// so lead with the chapter containing the playhead.
    ///
    /// A non-finite position leads with the first chapter: `CMTimeGetSeconds` answers NaN
    /// for an invalid/indefinite time — which is what the engine reports before the first
    /// frame lands — and `Duration.seconds(_:)` traps on it.
    nonisolated static func leadingRowID(chapters: [Chapter], atSeconds seconds: Double) -> TrackMenuRowID? {
        guard seconds.isFinite else { return chapters.first.map { .chapter($0.id) } }
        return (chapters.last { $0.start <= .seconds(seconds) } ?? chapters.first).map { .chapter($0.id) }
    }

    var body: some View {
        // The outer `LazyVStack` in `TrackMenuPanel` realizes these rows lazily, so a 30–60 chapter
        // movie defers off-screen rows (no build+measure hang on present).
        ForEach(chapters) { chapter in
            MenuRow(rowID: .chapter(chapter.id), isSelected: false, action: { onSelect(chapter) }) {
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

    /// The row the panel opens scrolled to (and focuses on tvOS): the active rate,
    /// falling back to the first.
    nonisolated static func leadingRowID(options: [Double], selected: Double) -> TrackMenuRowID? {
        (options.contains(selected) ? selected : options.first).map { .rate($0) }
    }

    var body: some View {
        ForEach(options, id: \.self) { rate in
            MenuRow(rowID: .rate(rate), isSelected: rate == selected, action: { onSelect(rate) }) {
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

// MARK: - Panel chrome

/// The scrollable Liquid Glass panel every track menu is presented in (same `.regular`
/// glass + white hairline as the chips), dark-pinned so the design tokens resolve to the
/// immersive palette.
///
/// It opens SCROLLED TO `leadingRowID` — the selected track / rate / current chapter
/// pinned to the top of the visible region — instead of at the top of the list. When that
/// row is near the end the scroll view's own clamp pins the list bottom; no manual math.
/// Width and height are the presenting panel's to set (`panelWidth`/`panelHeight`), fed by
/// the content-height report.
struct TrackMenuPanel<Content: View>: View {
    let kind: PlayerControlsView.TrackMenuKind
    let leadingRowID: TrackMenuRowID?
    let onContentHeightChange: (CGFloat) -> Void
    /// Run once the panel has seated its scroll position, in the SAME task — tvOS lands
    /// first focus here. Two independent `.task`s (one per concern) race with no defined
    /// order, and focusing a row the scroll hasn't seated yet drags the offset back.
    var onSeated: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(idType: TrackMenuRowID.self)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        ScrollView {
            // No in-panel title: the chip that opened this already names the menu. Just the rows,
            // clipped to `shape` (below) so they scroll cleanly under the panel's rounded corners.
            LazyVStack(alignment: .leading, spacing: 2) {
                content()
            }
            .scrollTargetLayout()
            .padding(.horizontal, Space.s8)
            // The vertical inset is the SCROLL VIEW's margin, not the stack's padding: as
            // padding it scrolls, so `anchor: .top` parked the target row against the panel's
            // bare top edge — its platter corner colliding with the panel's — and a first-row
            // target opened 8pt scrolled down. As a content margin it's a fixed inset the
            // offset can't eat. It's outside the measured content, so add it back below.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                onContentHeightChange($0 + Space.s8 * 2)
            }
        }
        .contentMargins(.vertical, Space.s8, for: .scrollContent)
        .scrollPosition($position, anchor: .top)
        // Seeding `ScrollPosition(id:anchor:)` in `init` renders at the top of the list and
        // stays there — the lazy stack hasn't realized the target row when the scroll view
        // takes its first offset, so the position has nothing to resolve against. Scrolling
        // from `.task` (after that first layout) is what actually lands it, and it still
        // beats the first frame the user sees: the panel grows in from the chip's corner.
        // Rows past the end clamp themselves, so there's no math here.
        .task {
            if let leadingRowID { position.scrollTo(id: leadingRowID, anchor: .top) }
            onSeated?()
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        // The in-panel MenuHeader was removed; name the panel container for VoiceOver so the
        // opened menu still announces which list it is (the opening chip is hidden while open).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.accessibilityTitle)
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
                // The undecodable case: shown, dimmed, unpickable, and it says why.
                AudioTrack(
                    id: .vlc("4"),
                    displayName: "Japanese",
                    languageCode: "jpn",
                    detailLabel: "TrueHD · 7.1",
                    isUnsupported: true
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

/// The real panel at a height that forces overflow: confirms there is no in-panel title, the
/// first row sits under the rounded top with its inset intact, and the bottom clip shows.
#Preview("Track panel · no header", traits: .sizeThatFitsLayout) {
    TrackMenuPanel(kind: .audio,
                   leadingRowID: .track(.jellyfinStream(1)),
                   onContentHeightChange: { _ in }) {
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
    .frame(width: 320, height: 200)
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// 30 tracks — deeper than any panel is tall — so the opening scroll position is visible
/// rather than inferred. Shared by the two panel-position specimens below.
private func previewSubtitleTracks() -> [SubtitleTrack] {
    (0..<30).map {
        SubtitleTrack(id: .jellyfinStream($0),
                      displayName: String(format: "Track %02d", $0),
                      languageCode: "eng",
                      isForced: false)
    }
}

/// The seat fix, in pixels: the panel must open with the SELECTED row flush against its
/// top edge, not at the top of the list. Track 10 of 30 is deep enough that a top-scrolled
/// panel can't be mistaken for a seated one, and far enough from the end that seating it
/// at the top doesn't hit the clamp (that case is the next preview — at this panel height
/// anything past Track 18 clamps instead).
#Preview("Subtitle panel · selected at top", traits: .sizeThatFitsLayout) {
    TrackMenuPanel(kind: .subtitles,
                   leadingRowID: .track(.jellyfinStream(10)),
                   onContentHeightChange: { _ in }) {
        SubtitleTrackMenu(tracks: previewSubtitleTracks(),
                          selectedID: .jellyfinStream(10),
                          onSelect: { _ in })
    }
    .frame(width: 256, height: 520)
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// The clamp half: a selection close enough to the end that seating it at the top would
/// scroll past the content. The scroll view's own clamp wins — the list bottom is pinned,
/// with no empty space under the last row.
#Preview("Subtitle panel · clamped to bottom", traits: .sizeThatFitsLayout) {
    TrackMenuPanel(kind: .subtitles,
                   leadingRowID: .track(.jellyfinStream(28)),
                   onContentHeightChange: { _ in }) {
        SubtitleTrackMenu(tracks: previewSubtitleTracks(),
                          selectedID: .jellyfinStream(28),
                          onSelect: { _ in })
    }
    .frame(width: 256, height: 520)
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// The regression guard: a list shorter than the panel must not shift at all, even with a
/// non-first row targeted. Content smaller than the container has nowhere to scroll, so 2.0×
/// sits where it always did — last row, bottom of the stack.
#Preview("Speed panel · short list", traits: .sizeThatFitsLayout) {
    TrackMenuPanel(kind: .speed,
                   leadingRowID: .rate(2.0),
                   onContentHeightChange: { _ in }) {
        SpeedMenu(options: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0], selected: 2.0, onSelect: { _ in })
    }
    .frame(width: 160, height: 520)
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// The zero-offset case, which the old scrolling `Space.s8` padding broke: targeting the
/// FIRST row of an overflowing list must leave the panel at rest, with the full 8pt inset
/// above the Off platter. When the inset scrolled, `anchor: .top` pulled the row up to the
/// panel's bare edge and the list opened 8pt down from its own start.
#Preview("Subtitle panel · Off selected, overflowing", traits: .sizeThatFitsLayout) {
    TrackMenuPanel(kind: .subtitles,
                   leadingRowID: .subtitlesOff,
                   onContentHeightChange: { _ in }) {
        SubtitleTrackMenu(tracks: previewSubtitleTracks(),
                          selectedID: nil,
                          onSelect: { _ in })
    }
    .frame(width: 256, height: 520)
    .padding(40)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
