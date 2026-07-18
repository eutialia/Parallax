import Foundation

public struct MediaCollection: Sendable, Hashable, Identifiable {
    public let id: CollectionID
    public let name: String
    public let collectionType: CollectionType
    public let primaryTag: ImageTag?
    /// BlurHash per image, keyed by the image TAG (unique per image on the server), so an
    /// `imageRef(_:)` can hand its decoded blur to the placeholder. Keying by tag rather than
    /// image type handles indexed backdrops uniformly — each backdrop tag maps to its own hash.
    public let blurHashes: [ImageTag: String]

    public init(
        id: CollectionID, name: String, collectionType: CollectionType, primaryTag: ImageTag?,
        blurHashes: [ImageTag: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
        self.primaryTag = primaryTag
        self.blurHashes = blurHashes
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        switch kind {
        case .primary:
            guard let tag = primaryTag else { return nil }
            return ImageRef(itemID: ItemID(rawValue: id.rawValue), kind: .primary, tag: tag, blurHash: blurHashes[tag])
        default:
            return nil
        }
    }
}
