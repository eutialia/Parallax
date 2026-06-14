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
struct HeroOverview: View {
    let text: String
    let regularWidth: Bool

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .lineLimit(3)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: HeroMetrics.overviewMaxWidth(regularWidth: regularWidth),
                alignment: .leading
            )
    }
}

extension HeroOverview {
    init?(item: Item, regularWidth: Bool) {
        guard let overview = item.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty
        else { return nil }
        self.text = OverviewFormatting.heroBlurb(from: overview)
        self.regularWidth = regularWidth
    }
}

// MARK: - Detail

/// Full overview in detail scroll bodies — paragraph gaps on each Jellyfin `\n`, no line cap.
struct DetailOverview: View {
    let text: String

    private var paragraphs: [String] { OverviewFormatting.paragraphs(from: text) }

    var body: some View {
        Group {
            if paragraphs.count <= 1 {
                Text(paragraphs.first ?? text)
            } else {
                VStack(alignment: .leading, spacing: Space.s12) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                    }
                }
            }
        }
    }
}
