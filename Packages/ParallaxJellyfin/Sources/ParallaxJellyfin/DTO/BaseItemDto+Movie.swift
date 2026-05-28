import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toMovie() -> Movie? {
        guard let id, let name else { return nil }
        let runtime: Duration?
        if let ticks = runTimeTicks {
            runtime = .microseconds(ticks / 10)
        } else {
            runtime = nil
        }
        let backdrops = (backdropImageTags ?? []).map(ImageTag.init(rawValue:))
        return Movie(
            id: ItemID(rawValue: id),
            title: name,
            overview: overview,
            year: productionYear,
            runtime: runtime,
            communityRating: communityRating.map(Double.init),
            officialRating: officialRating,
            genres: genres ?? [],
            primaryTag: imageTags?["Primary"].map(ImageTag.init(rawValue:)),
            backdropTags: backdrops,
            logoTag: imageTags?["Logo"].map(ImageTag.init(rawValue:)),
            thumbTag: imageTags?["Thumb"].map(ImageTag.init(rawValue:)),
            userData: userData?.toUserItemData() ?? .absent
        )
    }
}
