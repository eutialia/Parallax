import SwiftUI
import ParallaxJellyfin

/// The expanded info card opened from `DetailInfoSection`: the full overview plus every metadata
/// field, dimmed over the detail screen. A form-sized sheet on iPhone/iPad (`.presentationSizing`
/// `.form`, the same centered card Settings uses) and a centered modal on tvOS, where the sheet
/// is system-managed — focus moves into it and Menu dismisses it.
///
/// Wide layouts (iPad / Apple TV) split into two columns — overview beside the metadata — so the
/// card uses the screen instead of one tall stack; iPhone stacks them. No explicit close control:
/// dismissal is the platform's standard modal gesture — swipe-down / tap-outside on iOS, the Menu
/// button on tvOS (device-confirmed).
struct DetailInfoModal: View {
    let info: DetailInfo

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        #if os(tvOS)
        // tvOS is presented via `fullScreenCover` (Apple's documented "expand the description"
        // pattern — a tvOS `.sheet` sizes its card to the content's ideal height and overflows the
        // screen, clipping the bottom). The cover fills the screen, so paint our own dimmed
        // backdrop and float a HEIGHT-BOUNDED card on top. The overview inside is a focusable,
        // self-scrolling `UITextView` (see `tvCard`), so a long synopsis is reachable with the
        // remote — SwiftUI `Text` is never focusable, so it would be a dead scroll otherwise.
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            tvCard
                .frame(maxWidth: 1500)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.86 }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .focusSection()
        }
        #else
        scrollCard
            .presentationSizing(.form)
            .presentationBackground(Color.background)
        #endif
    }

    #if os(tvOS)
    /// tvOS card: a fixed header above a two-column body whose overview is a focusable,
    /// self-scrolling `FocusableScrollText` (`UITextView`). NO outer `ScrollView` here — nesting a
    /// SwiftUI scroll view around the text view would fight it for scroll + focus. The card is
    /// height-bounded by `body`, the header is fixed, and the text view fills the rest and scrolls.
    private var tvCard: some View {
        VStack(alignment: .leading, spacing: Space.s26) {
            header
            HStack(alignment: .top, spacing: Space.s40) {
                tvOverviewColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                metadataBlock
                    .frame(maxWidth: metadataColumnWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(modalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tvOverviewColumn: some View {
        if let overview = info.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: Space.s12) {
                DetailSectionLabel("Overview")
                // Paragraph breaks become blank lines so the UITextView shows them (it has no
                // SwiftUI paragraph-spacing equivalent).
                FocusableScrollText(text: OverviewFormatting.paragraphs(from: overview).joined(separator: "\n\n"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
    #else
    private var scrollCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s26) {
                header
                bodyColumns
            }
            .padding(modalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Overview beside metadata on iPad, stacked on iPhone. (tvOS uses `tvCard` instead — its
    /// overview is a focusable scrolling text view rather than plain `Text`.)
    @ViewBuilder
    private var bodyColumns: some View {
        if idiom == .compact {
            overviewBlock
            metadataBlock
        } else {
            HStack(alignment: .top, spacing: Space.s40) {
                overviewBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadataBlock
                    .frame(maxWidth: metadataColumnWidth, alignment: .leading)
            }
        }
    }
    #endif

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text(info.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tagline = info.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.callout).italic()
                    .foregroundStyle(Color.secondaryLabel)
            }
            DetailInfoFactsRow(facts: info.facts)
        }
    }

    // MARK: - Columns

    #if !os(tvOS)
    @ViewBuilder
    private var overviewBlock: some View {
        if let overview = info.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: Space.s12) {
                DetailSectionLabel("Overview")
                DetailOverview(text: overview)
                    .font(.callout)
                    .foregroundStyle(Color.label)
            }
        }
    }
    #endif

    @ViewBuilder
    private var metadataBlock: some View {
        let fields = info.fields
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: Space.s22) {
                ForEach(fields) { DetailInfoFieldView(field: $0) }
            }
        }
    }

    // MARK: - Metrics

    /// Cap the metadata column so the overview takes the lion's share of a wide card; tvOS is far
    /// wider, so it gets a wider cap.
    private var metadataColumnWidth: CGFloat { idiom == .tv ? 520 : 300 }

    private var modalPadding: EdgeInsets {
        switch idiom {
        case .tv:
            return EdgeInsets(top: Space.s40, leading: Space.s40, bottom: Space.s40, trailing: Space.s40)
        default:
            return EdgeInsets(top: Space.s30, leading: Space.s26, bottom: Space.s30, trailing: Space.s26)
        }
    }
}

#if DEBUG
// Render the card directly at a concrete form-sheet width (the `presentationSizing` / background
// are no-ops outside a real sheet) so the two-column split and genre chips are legible without
// the sheet's downscaling.
#Preview("Info modal · iPad", traits: .fixedLayout(width: 640, height: 520)) {
    DetailInfoModal(info: .preview)
        .frame(width: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .environment(\.appIdiom, .regular)
}

#Preview("Info modal · iPhone", traits: .fixedLayout(width: 420, height: 720)) {
    DetailInfoModal(info: .preview)
        .frame(width: 393)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .environment(\.appIdiom, .compact)
}
#endif
