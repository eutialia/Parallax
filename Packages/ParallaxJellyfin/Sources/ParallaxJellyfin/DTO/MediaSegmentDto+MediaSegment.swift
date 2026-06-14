import Foundation
import JellyfinAPI
import ParallaxCore

extension MediaSegmentDto {
    /// Maps the SDK DTO to the domain model, or nil when the positional data is
    /// unusable: missing start/end, or a non-positive span (`end <= start`, which a
    /// half-open `contains` could never match and `skip` would seek to ~0). Ticks are
    /// 100-ns units — `/10` converts to microseconds, matching `BaseItemDto.toEpisode`'s
    /// runtime mapping.
    func toMediaSegment() -> MediaSegment? {
        guard let id, let startTicks, let endTicks, endTicks > startTicks else { return nil }
        return MediaSegment(
            id: id,
            kind: Self.kind(from: type),
            start: .microseconds(startTicks / 10),
            end: .microseconds(endTicks / 10)
        )
    }

    private static func kind(from type: MediaSegmentType?) -> MediaSegmentKind {
        switch type {
        case .intro: .intro
        case .outro: .outro
        case .recap: .recap
        case .preview: .preview
        case .commercial: .commercial
        case .unknown, nil: .unknown
        }
    }
}
