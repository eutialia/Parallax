import Foundation

public struct Episode: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let seriesID: ItemID
    public let seasonID: ItemID
    public let name: String
    public let indexNumber: Int?
    public let parentIndexNumber: Int?   // season number
    public let overview: String?
    public let runtime: Duration?
    public let primaryTag: ImageTag?
    public let userData: UserItemData

    public init(
        id: ItemID, seriesID: ItemID, seasonID: ItemID, name: String,
        indexNumber: Int?, parentIndexNumber: Int?,
        overview: String?, runtime: Duration?,
        primaryTag: ImageTag?, userData: UserItemData
    ) {
        self.id = id; self.seriesID = seriesID; self.seasonID = seasonID
        self.name = name; self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.overview = overview; self.runtime = runtime
        self.primaryTag = primaryTag; self.userData = userData
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        // Switch (not guard case) so the compiler errors if ImageKind
        // gains a new case — Episode would otherwise silently eat it.
        switch kind {
        case .primary:
            guard let tag = primaryTag else { return nil }
            return ImageRef(itemID: id, kind: .primary, tag: tag)
        case .backdrop, .logo, .thumb, .banner, .art, .disc:
            return nil
        }
    }
}
