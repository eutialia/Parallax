import Foundation

public struct Series: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let title: String
    public let overview: String?
    public let year: Int?
    public let status: String?
    public let communityRating: Double?
    public let officialRating: String?
    public let genres: [String]
    public let primaryTag: ImageTag?
    public let backdropTags: [ImageTag]
    public let logoTag: ImageTag?
    public let thumbTag: ImageTag?
    public let bannerTag: ImageTag?
    public let dateAdded: Date?
    /// `var` only for the `withUserData` copy below; immutable to callers.
    public private(set) var userData: UserItemData
    /// BlurHash per image, keyed by the image TAG (unique per image on the server), so an
    /// `imageRef(_:)` can hand its decoded blur to the placeholder. Keying by tag rather than
    /// image type handles indexed backdrops uniformly — each backdrop tag maps to its own hash.
    public let blurHashes: [ImageTag: String]

    public init(
        id: ItemID, title: String, overview: String?, year: Int?, status: String?,
        communityRating: Double?, officialRating: String?,
        genres: [String],
        primaryTag: ImageTag?, backdropTags: [ImageTag], logoTag: ImageTag?,
        thumbTag: ImageTag?, bannerTag: ImageTag?,
        dateAdded: Date? = nil,
        userData: UserItemData,
        blurHashes: [ImageTag: String] = [:]
    ) {
        self.id = id; self.title = title; self.overview = overview; self.year = year
        self.status = status
        self.communityRating = communityRating; self.officialRating = officialRating
        self.genres = genres
        self.primaryTag = primaryTag; self.backdropTags = backdropTags
        self.logoTag = logoTag; self.thumbTag = thumbTag; self.bannerTag = bannerTag
        self.dateAdded = dateAdded
        self.userData = userData
        self.blurHashes = blurHashes
    }

    /// Same item, updated watch state. A mutated copy — NOT an init call listing every field,
    /// which silently zeroed any field someone forgot to thread through (blurHashes, once).
    public func withUserData(_ userData: UserItemData) -> Series {
        var copy = self; copy.userData = userData; return copy
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        let tag: ImageTag?
        switch kind {
        case .primary: tag = primaryTag
        case .backdrop(let i): tag = backdropTags.indices.contains(i) ? backdropTags[i] : nil
        case .logo: tag = logoTag
        case .thumb: tag = thumbTag
        case .banner: tag = bannerTag
        case .art, .disc: tag = nil
        }
        guard let tag else { return nil }
        return ImageRef(itemID: id, kind: kind, tag: tag, blurHash: blurHashes[tag])
    }
}
