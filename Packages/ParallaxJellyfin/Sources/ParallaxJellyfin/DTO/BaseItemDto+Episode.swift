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
            seasonImageRef: Self.seasonImageRef(from: self),
            seriesImageRef: Self.seriesImageRef(from: self),
            userData: userData?.toUserItemData() ?? .absent
        )
    }

    private static func seriesImageRef(from dto: BaseItemDto) -> ImageRef? {
        guard let seriesID = dto.seriesID else { return nil }
        if let ref = parentImageRef(
            itemID: seriesID,
            tag: dto.seriesPrimaryImageTag,
            kind: .primary
        ) { return ref }
        if let ref = parentImageRef(
            itemID: seriesID,
            tag: dto.seriesThumbImageTag,
            kind: .thumb
        ) { return ref }
        return nil
    }

    /// Parent image hints on list DTOs (resume/next-up). When absent, the repository
    /// batch-fetches seasons by `seasonID` before home shelves render.
    private static func seasonImageRef(from dto: BaseItemDto) -> ImageRef? {
        if let ref = parentImageRef(
            itemID: dto.parentPrimaryImageItemID ?? dto.seasonID,
            tag: dto.parentPrimaryImageTag,
            kind: .primary
        ) { return ref }
        if let ref = parentImageRef(
            itemID: dto.parentThumbItemID ?? dto.seasonID,
            tag: dto.parentThumbImageTag,
            kind: .thumb
        ) { return ref }
        return nil
    }

    private static func parentImageRef(itemID: String?, tag: String?, kind: ImageKind) -> ImageRef? {
        guard let itemID, let tag else { return nil }
        return ImageRef(itemID: ItemID(rawValue: itemID), kind: kind, tag: ImageTag(rawValue: tag))
    }
}
