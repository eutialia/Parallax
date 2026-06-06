import Foundation

public struct HomeHeroFeedEntry: Sendable, Hashable, Identifiable {
    public var id: ItemID { presentation.id }
    public let presentation: Item
    public let playTarget: Item
    public let eyebrow: HeroEyebrow

    public var playButtonTitle: String {
        Self.playButtonTitle(for: playTarget)
    }

    public init(presentation: Item, playTarget: Item, eyebrow: HeroEyebrow) {
        self.presentation = presentation
        self.playTarget = playTarget
        self.eyebrow = eyebrow
    }

    public static func playButtonTitle(for playTarget: Item) -> String {
        guard hasResumeProgress(playTarget) else { return "Play" }
        switch playTarget {
        case .episode(let episode):
            if let season = episode.parentIndexNumber, let index = episode.indexNumber {
                return "Resume S\(season) E\(index)"
            }
            return "Resume"
        case .movie:
            return "Resume"
        case .series:
            return "Play"
        }
    }

    private static func hasResumeProgress(_ item: Item) -> Bool {
        let userData = item.userData
        return userData.playbackPositionTicks > 0 && !userData.played
    }
}