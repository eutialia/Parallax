import Foundation

public struct MediaCollection: Sendable, Hashable, Identifiable {
    public let id: CollectionID
    public let name: String
    public let collectionType: CollectionType
    public let primaryTag: ImageTag?

    public init(id: CollectionID, name: String, collectionType: CollectionType, primaryTag: ImageTag?) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
        self.primaryTag = primaryTag
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        switch kind {
        case .primary:
            guard let tag = primaryTag else { return nil }
            return ImageRef(itemID: ItemID(rawValue: id.rawValue), kind: .primary, tag: tag)
        default:
            return nil
        }
    }
}
