import Foundation
import JellyfinAPI
import ParallaxCore

extension BaseItemDto {
    func toMediaCollection() -> MediaCollection? {
        guard let id, let name else { return nil }
        // SDK CollectionType is a String enum; .rawValue gives the lowercase string.
        // Our domain CollectionType is a different type — qualify to resolve the ambiguity.
        let domainType: ParallaxCore.CollectionType
        switch collectionType?.rawValue.lowercased() {
        case "movies": domainType = .movies
        case "tvshows": domainType = .tvShows
        case .none: domainType = .other("unknown")
        case .some(let other): domainType = .other(other)
        }
        let primary = imageTags?["Primary"].map(ImageTag.init(rawValue:))
        return MediaCollection(
            id: CollectionID(rawValue: id),
            name: name,
            collectionType: domainType,
            primaryTag: primary
        )
    }
}
