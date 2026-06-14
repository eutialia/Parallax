import SwiftUI
import ParallaxJellyfin

/// The detail page's interactive info teaser: a height-clamped, full-width glass panel showing
/// only the overview, with a "More" affordance bottom-trailing. Tapping it opens
/// `DetailInfoModal` — the full overview plus every metadata field — as a dimmed card.
///
/// This is also the fix for the tvOS detail-scroll dead end. Below the hero action row the page
/// was all non-focusable `Text` (overview, metadata lines), so the focus engine had nowhere to go
/// and Down did nothing — a Movie, or a Series with no season shelf, simply wouldn't scroll. The
/// section is a Button: one focusable element below the fold, so the focus engine reaches it and
/// the page scrolls, exactly like the Apple TV app's tap-to-expand synopsis.
struct DetailInfoSection: View {
    let info: DetailInfo

    @Environment(\.appIdiom) private var idiom
    @State private var isExpanded = false

    var body: some View {
        // `info.teaser` flattens the overview to one flowing paragraph (so `lineLimit` counts
        // rendered lines, not Jellyfin's `\n` breaks) and falls back to tagline/genres/facts, so
        // the card is never just a lone "More" chevron. Bound once per body eval.
        let teaser = info.teaser
        Button { isExpanded = true } label: {
            // No "More" affordance — the glass panel itself reads as tappable, and the tail
            // truncation already signals there's more. A bottom fade softens the cut-off line so
            // it reads as "continues" rather than a hard ellipsis.
            Text(teaser)
                .font(.callout)
                .foregroundStyle(Color.label)
                .lineLimit(idiom == .compact ? 3 : 4)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(teaserFade)
            // A custom `glassPanel` background (not `.buttonStyle(.glass)`): the native glass
            // button hugs its content, but the section must be full-width — `maxWidth: .infinity`
            // on a panel background fills the row. Mirrors Settings' tappable server card.
                .padding(Space.s18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: Radius.card)
                .contentShape(.rect)
        }
        // Chrome card → the gentle tvOS chip focus lift (`.plain` on iOS); see `tvChipButton`.
        .tvChipButton()
        // Force the button itself full-width: a plain/chip button proposes only its label's ideal
        // width, so the inner `maxWidth: .infinity` can't expand without this outer frame.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
        // Turn the row's full width into one focus target so Up/Down from the action row (or the
        // shelves below it on Series) diverts here rather than missing it on a straight-line
        // search — the tvOS catalog sample's `focusSection` guidance. No-op on iOS.
        .tvFocusSection()
        // tvOS expands via `fullScreenCover` (the card is drawn + height-bounded inside
        // `DetailInfoModal` so it can't overflow the screen); iOS/iPadOS use a form sheet.
        #if os(tvOS)
        .fullScreenCover(isPresented: $isExpanded) { DetailInfoModal(info: info) }
        #else
        .sheet(isPresented: $isExpanded) { DetailInfoModal(info: info) }
        #endif
    }

    /// Softens the bottom of the clamped teaser so the truncated last line fades out (reads as
    /// "continues") instead of ending on a hard ellipsis. Top stays fully opaque; only the final
    /// ~quarter dims, so a short single-line teaser is barely affected.
    private var teaserFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.72),
                .init(color: .black.opacity(0.35), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#if DEBUG
#Preview("Info section", traits: .fixedLayout(width: 440, height: 360)) {
    // Use an explicit `.frame(width:)` — `.fixedLayout` proposes an unspecified (ideal) size to
    // the content, which collapses the section's `maxWidth: .infinity` to its content width and
    // mis-renders it as a half-width card. The real screen (a ScrollView) proposes a concrete
    // width, so the section fills the row as it does here. (The preview device's Dynamic Type is
    // also inflated, so the teaser font reads larger here than the in-app `.callout`.)
    DetailInfoSection(info: .preview)
        .frame(width: 393)
        .padding(.vertical, Space.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .environment(\.appIdiom, .compact)
}
#endif
