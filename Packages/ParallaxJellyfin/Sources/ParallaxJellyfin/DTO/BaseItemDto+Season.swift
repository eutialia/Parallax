import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toSeason() -> Season? {
        guard let id, let name, let seriesIdRaw = seriesID else { return nil }
        return Season(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesIdRaw),
            name: name,
            indexNumber: indexNumber,
            primaryTag: imageTags?["Primary"].map(ImageTag.init(rawValue:)),
            thumbTag: imageTags?["Thumb"].map(ImageTag.init(rawValue:)),
            episodeCount: childCount
        )
    }
}
