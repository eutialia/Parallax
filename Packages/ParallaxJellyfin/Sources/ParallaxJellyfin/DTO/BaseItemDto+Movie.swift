import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toMovie() -> Movie? {
        // Guard the kind: a scoped /Items search (includeItemTypes=[movie])
        // can still return BoxSet/Folder children, which have id+name and
        // would otherwise be projected into a Movie that fails to open.
        guard type == .movie, let id, let name else { return nil }
        let runtime: Duration?
        if let ticks = runTimeTicks {
            runtime = .microseconds(ticks / 10)
        } else {
            runtime = nil
        }
        let backdrops = (backdropImageTags ?? []).map(ImageTag.init(rawValue:))
        let video = mediaStreams?.first { $0.type == .video }
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
            userData: userData?.toUserItemData() ?? .absent,
            width: video?.width,
            height: video?.height,
            videoRangeType: video?.videoRangeType?.rawValue
        )
    }
}
