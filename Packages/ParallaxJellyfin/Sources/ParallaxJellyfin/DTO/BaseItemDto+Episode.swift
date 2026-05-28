import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toEpisode() -> Episode? {
        guard type == .episode, let id, let name,
              let seriesIdRaw = seriesID,
              let seasonIdRaw = seasonID else { return nil }
        let runtime: Duration?
        if let ticks = runTimeTicks {
            runtime = .microseconds(ticks / 10)
        } else {
            runtime = nil
        }
        return Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesIdRaw),
            seasonID: ItemID(rawValue: seasonIdRaw),
            name: name,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            overview: overview,
            runtime: runtime,
            primaryTag: imageTags?["Primary"].map(ImageTag.init(rawValue:)),
            userData: userData?.toUserItemData() ?? .absent
        )
    }
}
