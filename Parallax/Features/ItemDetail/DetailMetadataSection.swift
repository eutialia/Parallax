import SwiftUI

/// The detail page's "open ledger": the overview/tagline column beside the labeled metadata ledger
/// (Genres, Director, Studios, Cast & Crew), painted straight onto the page floor — no card, no
/// modal. Compact stacks the two; iPad / Apple TV set them side by side with the ledger pinned to a
/// fixed column. The overview is the ONLY interactive piece (expand-in-place); the ledger is inert
/// text + chips.
struct DetailMetadataSection: View {
    let info: DetailInfo

    @Environment(\.appIdiom) private var idiom

    #if os(tvOS)
    @FocusState private var fallbackFocused: Bool
    #endif

    var body: some View {
        if info.hasContent {
            layout
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                // Full-width focus target so Up/Down from the action row (or the shelves below on
                // Series) diverts into the section instead of missing it on a straight-line search —
                // the tvOS catalog sample's `focusSection` guidance. No-op on iOS.
                .tvFocusSection()
        }
    }

    // Column-emptiness is decided from these two alone — every consumer below (visibility, the
    // placeholder, the tvOS focus fallback) reads the same pair, so the rules can't drift apart.
    private var hasProse: Bool { info.overview?.isEmpty == false }
    private var hasTagline: Bool { info.tagline?.isEmpty == false }

    /// The overview column as `layout` consumes it. On tvOS a no-prose title still needs a focus
    /// stop here — without one the engine could never scroll the inert ledger (genres/cast) into
    /// view on a page whose only other focusables are the hero buttons — so the COLUMN (placeholder
    /// or tagline) becomes a plain focusable reading region wearing the same quiet platter, sized
    /// like the overview block it stands in for (not the whole section row). `.focusable`, not a
    /// Button: Select does nothing, and VoiceOver reads the column's text instead of an unlabeled
    /// button.
    @ViewBuilder
    private var overviewColumnSlot: some View {
        #if os(tvOS)
        if hasProse {
            overviewColumn
        } else {
            overviewColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TVQuietReadingPlatter(focused: fallbackFocused))
                .focusable()
                .focused($fallbackFocused)
                .accessibilityElement(children: .combine)
        }
        #else
        overviewColumn
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        switch idiom {
        case .compact:
            VStack(alignment: .leading, spacing: Space.s22) {
                if showsOverviewColumn { overviewColumnSlot }
                if !info.fields.isEmpty { ledger }
            }
        case .regular, .tv:
            HStack(alignment: .top, spacing: Space.s40) {
                if showsOverviewColumn {
                    overviewColumnSlot
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // The old modal's `metadataColumnWidth`, promoted to the page — the overview takes
                // the lion's share; the ledger holds a fixed reading column.
                if !info.fields.isEmpty {
                    ledger
                        .frame(width: idiom == .tv ? 520 : 300, alignment: .leading)
                }
            }
        }
    }

    /// Wide layouts always keep the column — a no-overview title renders the placeholder there so
    /// the fixed ledger column doesn't hug the left content edge. Compact stacks, so an empty
    /// column would only add a dead spacing slot above a chips-only ledger; it drops instead.
    private var showsOverviewColumn: Bool {
        idiom != .compact || hasTagline || hasProse
    }

    @ViewBuilder
    private var overviewColumn: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let tagline = info.tagline, hasTagline {
                Text(tagline)
                    .font(.detailProse).italic()
                    .foregroundStyle(Color.secondaryLabel)
            }
            if let overview = info.overview, hasProse {
                DetailOverview(text: overview)
            } else if idiom != .compact, !hasTagline {
                // Stand-in that holds the two-column geometry when a title ships no prose AT ALL —
                // without it the fixed ledger column hugs the left content edge and the row reads
                // broken. A tagline already holds the column, so the stand-in never contradicts one.
                // Tertiary ink: an absence, not content. (Compact stacks, so it needs no stand-in;
                // on tvOS this also gives the fallback focus region real text to announce.)
                Text("No overview available")
                    .font(.detailProse).italic()
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
    }

    /// The labeled ledger — informational, so it carries NO focus affordance on tvOS (plain Text /
    /// chips are never focusable). Genres render as chips, the rest as comma-joined text.
    private var ledger: some View {
        VStack(alignment: .leading, spacing: Space.s22) {
            ForEach(info.fields) { DetailInfoFieldView(field: $0) }
        }
    }
}

/// The expandable overview: a line-clamped text that expands in place (content below pushes down).
/// One input model on every platform — the WHOLE block is the toggle (tap on touch, Select on
/// tvOS; the Apple TV-app pattern) and the More/Less caption is the passive visual affordance.
/// tvOS wears the quiet focus platter; touch stays chrome-free.
private struct DetailOverview: View {
    /// ONE string for both states, computed once — paragraph breaks preserved as blank lines.
    /// Collapsed and expanded must render the same content (expansion only lifts the line limit):
    /// flattening for the clamp and re-paragraphing on expand made the text visibly rewrite itself
    /// on toggle. A break inside the clamp window costs a line of budget; that's honest rendering.
    private let displayText: String

    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    // Hidden-probe measurements — the collapsed clamp vs the full text at the same width. `More`
    // shows only when the text actually overflows, and stays correct across width changes.
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    init(text: String) {
        displayText = OverviewFormatting.paragraphs(from: text).joined(separator: "\n\n")
    }

    private var isTruncated: Bool { fullHeight > clampedHeight + 0.5 }
    private var showAffordance: Bool { isTruncated || isExpanded }

    var body: some View {
        #if os(tvOS)
        tvBlock
        #else
        touchBlock
        #endif
    }

    /// Text + caption in one column — the shared label both platforms' toggle Buttons wrap.
    private var blockLabel: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            measuredOverview
            if showAffordance {
                affordanceLabel
            }
        }
    }

    #if os(tvOS)
    /// The whole block is the focusable Button; the More/Less caption is passive (part of the label).
    /// A QUIET platter marks focus — no lift/scale (`TVQuietButtonStyle`) — so the reading region
    /// reads as gently lit, not a jumping tile.
    ///
    /// Known limit (accepted 2026-07-15): an EXPANDED synopsis taller than the screen can't be
    /// panned — tvOS scrolls by moving focus, and this block is one focusable with (on movies)
    /// nothing below it. Needs a ~2,200+ character overview to trigger; the fix would resurrect
    /// the deleted FocusableScrollText machinery, judged not worth it for that tail.
    private var tvBlock: some View {
        Button { toggle() } label: {
            TVFocusReader { focused in
                blockLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(TVQuietReadingPlatter(focused: focused))
            }
        }
        .buttonStyle(TVQuietButtonStyle())
    }
    #else
    /// Touch: the WHOLE block toggles (the tvOS input model, converged) — the More/Less caption is
    /// the visual affordance, not the hit target: a caption-sized target is hard to hit and shifts
    /// position every toggle as the text grows. Always a Button, never a conditional swap: the
    /// affordance resolves from measurement a frame after appear, and branching on it would rebuild
    /// the subtree under a new identity mid-appear (and drop hardware-keyboard focusability, which
    /// the old section had). `toggle()` no-ops when nothing is hidden — the old teaser's guarded-tap
    /// precedent.
    private var touchBlock: some View {
        Button { toggle() } label: {
            blockLabel
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
    #endif

    private var affordanceLabel: some View {
        Text(isExpanded ? "Less" : "More")
            .font(.detailAffordance)
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color.secondaryLabel)
    }

    /// The overview text (clamped or expanded), capped to a comfortable ~72ch measure, with the
    /// truncation probe measuring at the same width. The probe only mounts while collapsed — its
    /// heights only drive the collapsed-state decisions, so the expanded reading state (where the
    /// user dwells on the longest texts) skips the two hidden full-text layouts.
    private var measuredOverview: some View {
        overviewText
            .frame(maxWidth: measureWidth, alignment: .leading)
            .background(alignment: .topLeading) {
                if !isExpanded { truncationProbe }
            }
    }

    private var overviewText: some View {
        styledText(lineLimit: isExpanded ? nil : collapsedLineLimit)
            // The mask stays ATTACHED in both states — an if/else here would give the two states
            // different structural identity (`_ConditionalContent`), degrading the expand spring
            // to a cross-fade. Both layers persist; only their opacity animates. The fade softens
            // the truncated last line so it reads as "continues", not a hard ellipsis.
            .mask {
                let dimmed = !isExpanded && isTruncated
                ZStack {
                    Color.black.opacity(dimmed ? 0 : 1)
                    collapsedFade.opacity(dimmed ? 1 : 0)
                }
            }
    }

    /// One styling chain for the visible text AND both probes — the probes must lay out with
    /// exactly the shipping font/wrapping or `isTruncated` measures a layout that never renders.
    private func styledText(lineLimit: Int?) -> some View {
        Text(displayText)
            .font(.detailProse)
            .foregroundStyle(Color.label)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Two hidden probes at the text column's width — the clamped height and the full height — so
    /// `isTruncated` stays accurate independent of width.
    private var truncationProbe: some View {
        ZStack(alignment: .topLeading) {
            styledText(lineLimit: collapsedLineLimit)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { clampedHeight = $0 }
            styledText(lineLimit: nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toggle() {
        // A fully-visible overview has nothing to reveal: Select/tap is a no-op, otherwise the
        // only effect would be conjuring a LESS caption out of nowhere. (Matters on tvOS, where
        // the block stays a Button regardless — it's the page's focus/scroll anchor.) Collapse
        // must always work once expanded.
        guard showAffordance else { return }
        withAnimation(reduceMotion ? nil : .organicSettle) {
            isExpanded.toggle()
        }
    }

    private var collapsedFade: LinearGradient {
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

    // Regular/tv clamp at 10, not a teaser: in the two-column layout the ledger column is nearly
    // always taller (~350pt regular / ~500pt tv vs ~22pt per text line), so a typical ≤10-line
    // overview shows whole — no More button (it self-hides under the limit) and no extra section
    // height. The clamp only bites on pathological synopses, which would otherwise shove a series'
    // season shelves below the fold (and would make the tvOS block's Select a permanent no-op).
    private var collapsedLineLimit: Int { idiom == .compact ? 4 : 10 }
    private var measureWidth: CGFloat { idiom == .tv ? 980 : 600 }
}

#if DEBUG
// Explicit `.frame(width:)` inside `.fixedLayout` — the layout proposes an unspecified (ideal) size,
// which would collapse the overview column's `maxWidth: .infinity` to its content width and
// mis-render the side-by-side split. The real screen (a ScrollView) proposes a concrete width, so
// the section fills the row as it does here.
#Preview("Ledger · compact", traits: .fixedLayout(width: 440, height: 620)) {
    ScrollView {
        DetailMetadataSection(info: .preview)
            .padding(.vertical, Space.s40)
    }
    .frame(width: 393)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .environment(\.appIdiom, .compact)
}

#Preview("Ledger · regular", traits: .fixedLayout(width: 1080, height: 520)) {
    ScrollView {
        DetailMetadataSection(info: .preview)
            .padding(.vertical, Space.s40)
    }
    .frame(width: 1024)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .environment(\.appIdiom, .regular)
}

// Regression guard for the no-overview wide layout: the placeholder must hold the left column so
// the fixed ledger doesn't hug the content edge. (A title with a TAGLINE but no overview shows the
// tagline INSTEAD of the placeholder — never both; see `overviewColumn`.)
#Preview("Ledger · regular · no overview", traits: .fixedLayout(width: 1080, height: 420)) {
    ScrollView {
        DetailMetadataSection(info: DetailInfo(
            tagline: nil,
            overview: nil,
            genres: ["Anime", "Comedy", "Music"],
            directors: [],
            studios: ["CloverWorks"],
            castAndCrew: ["Yoshino Aoyama", "Sayumi Suzushiro"]
        ))
        .padding(.vertical, Space.s40)
    }
    .frame(width: 1024)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .environment(\.appIdiom, .regular)
}
#endif
