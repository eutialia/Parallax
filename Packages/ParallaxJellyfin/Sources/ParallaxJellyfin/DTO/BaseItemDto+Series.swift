import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toSeries() -> Series? {
        guard let id, let name else { return nil }
        let backdrops = (backdropImageTags ?? []).map(ImageTag.init(rawValue:))
        return Series(
            id: ItemID(rawValue: id),
            title: name,
            overview: overview,
            year: productionYear,
            status: status,
            genres: genres ?? [],
            primaryTag: imageTags?["Primary"].map(ImageTag.init(rawValue:)),
            backdropTags: backdrops,
            logoTag: imageTags?["Logo"].map(ImageTag.init(rawValue:)),
            thumbTag: imageTags?["Thumb"].map(ImageTag.init(rawValue:)),
            bannerTag: imageTags?["Banner"].map(ImageTag.init(rawValue:)),
            userData: userData?.toUserItemData() ?? .absent
        )
    }
}
