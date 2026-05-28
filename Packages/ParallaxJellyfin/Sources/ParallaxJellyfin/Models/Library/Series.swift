import Foundation

public struct Series: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let title: String
    public let overview: String?
    public let year: Int?
    public let status: String?
    public let genres: [String]
    public let primaryTag: ImageTag?
    public let backdropTags: [ImageTag]
    public let logoTag: ImageTag?
    public let thumbTag: ImageTag?
    public let bannerTag: ImageTag?
    public let userData: UserItemData

    public init(
        id: ItemID, title: String, overview: String?, year: Int?, status: String?,
        genres: [String],
        primaryTag: ImageTag?, backdropTags: [ImageTag], logoTag: ImageTag?,
        thumbTag: ImageTag?, bannerTag: ImageTag?,
        userData: UserItemData
    ) {
        self.id = id; self.title = title; self.overview = overview; self.year = year
        self.status = status; self.genres = genres
        self.primaryTag = primaryTag; self.backdropTags = backdropTags
        self.logoTag = logoTag; self.thumbTag = thumbTag; self.bannerTag = bannerTag
        self.userData = userData
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
        return ImageRef(itemID: id, kind: kind, tag: tag)
    }
}
