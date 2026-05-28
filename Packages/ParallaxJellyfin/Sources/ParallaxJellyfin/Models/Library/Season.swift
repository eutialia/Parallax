import Foundation

public struct Season: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let seriesID: ItemID
    public let name: String
    public let indexNumber: Int?
    public let primaryTag: ImageTag?
    public let thumbTag: ImageTag?
    public let episodeCount: Int?

    public init(
        id: ItemID, seriesID: ItemID, name: String, indexNumber: Int?,
        primaryTag: ImageTag?, thumbTag: ImageTag?, episodeCount: Int?
    ) {
        self.id = id; self.seriesID = seriesID; self.name = name
        self.indexNumber = indexNumber
        self.primaryTag = primaryTag; self.thumbTag = thumbTag
        self.episodeCount = episodeCount
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        let tag: ImageTag?
        switch kind {
        case .primary: tag = primaryTag
        case .thumb: tag = thumbTag
        case .backdrop, .logo, .banner, .art, .disc: tag = nil
        }
        guard let tag else { return nil }
        return ImageRef(itemID: id, kind: kind, tag: tag)
    }
}
