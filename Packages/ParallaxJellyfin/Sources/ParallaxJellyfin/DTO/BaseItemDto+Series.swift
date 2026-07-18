import Foundation
import JellyfinAPI
import ParallaxCore

extension BaseItemDto {
    func toSeries() -> Series? {
        guard type == .series, let id, let name else { return nil }
        let backdrops = (backdropImageTags ?? []).map(ImageTag.init(rawValue:))
        return Series(
            id: ItemID(rawValue: id),
            title: name,
            overview: overview,
            year: productionYear,
            status: status,
            communityRating: communityRating.map(Double.init),
            officialRating: officialRating,
            genres: genres ?? [],
            primaryTag: imageTags?["Primary"].map(ImageTag.init(rawValue:)),
            backdropTags: backdrops,
            logoTag: imageTags?["Logo"].map(ImageTag.init(rawValue:)),
            thumbTag: imageTags?["Thumb"].map(ImageTag.init(rawValue:)),
            bannerTag: imageTags?["Banner"].map(ImageTag.init(rawValue:)),
            dateAdded: dateCreated,
            userData: userData?.toUserItemData() ?? .absent,
            blurHashes: tagBlurHashes
        )
    }
}
