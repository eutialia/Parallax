import SwiftUI
import ParallaxJellyfin
import ParallaxCore

// MARK: - Formatting

enum OverviewFormatting {
    /// Jellyfin overviews use single `\n` between paragraphs (not `\n\n`); blank lines
    /// are normalized away. Leading ideographic space (`　`) is trimmed — detail uses
    /// VStack spacing instead.
    private static let trimCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{3000}")
        return set
    }()

    static func paragraphs(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: trimCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Single flowing paragraph for hero truncation — `lineLimit` counts every rendered
    /// line fragment, so newlines would steal lines from the 3-line cap.
    static func heroBlurb(from text: String) -> String {
        paragraphs(from: text).joined(separator: " ")
    }
}

// MARK: - Hero

/// Jellyfin overview blurb in the hero foreground, between title and actions.
/// `.subheadline` auto-ramps on tvOS; only the measure is idiom-managed (HeroMetrics).
struct HeroOverview: View {
    let text: String

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .lineLimit(3)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: HeroMetrics.overviewMaxWidth(idiom: idiom),
                alignment: .leading
            )
    }
}

/// Hero overview that shrinks its line count to the space the foreground cap leaves. `ViewThatFits`
/// tries 5→1 lines and renders the tallest that fits the height the column proposes, so a roomy band
/// shows more of the blurb and a tight one shows less — the rest truncates with an ellipsis. Used in
/// the hero foreground's flexible subtitle slot (the fixed title/actions hold their size).
struct AdaptiveHeroOverview: View {
    let text: String

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ViewThatFits(in: .vertical) {
            line(5)
            line(4)
            line(3)
            line(2)
            line(1)
        }
        .frame(maxWidth: HeroMetrics.overviewMaxWidth(idiom: idiom), alignment: .leading)
    }

    private func line(_ limit: Int) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .lineLimit(limit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension AdaptiveHeroOverview {
    init?(item: Item) {
        guard let overview = item.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty
        else { return nil }
        self.text = OverviewFormatting.heroBlurb(from: overview)
    }
}
