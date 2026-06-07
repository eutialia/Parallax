import Foundation

public struct Episode: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let seriesID: ItemID
    public let seasonID: ItemID
    public let name: String
    public let indexNumber: Int?
    public let parentIndexNumber: Int?   // season number
    public let overview: String?
    public let runtime: Duration?
    public let primaryTag: ImageTag?
    /// Season folder art from Jellyfin's parent-primary fields (e.g. `season.jpg`).
    public let seasonImageRef: ImageRef?
    /// Series poster when season art is missing (DTO hint or repository fetch).
    public let seriesImageRef: ImageRef?
    public let dateAdded: Date?
    public let userData: UserItemData

    public init(
        id: ItemID, seriesID: ItemID, seasonID: ItemID, name: String,
        indexNumber: Int?, parentIndexNumber: Int?,
        overview: String?, runtime: Duration?,
        primaryTag: ImageTag?, seasonImageRef: ImageRef? = nil,
        seriesImageRef: ImageRef? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData
    ) {
        self.id = id; self.seriesID = seriesID; self.seasonID = seasonID
        self.name = name; self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.overview = overview; self.runtime = runtime
        self.primaryTag = primaryTag; self.seasonImageRef = seasonImageRef
        self.seriesImageRef = seriesImageRef
        self.dateAdded = dateAdded
        self.userData = userData
    }

    public func withSeasonImageRef(_ ref: ImageRef?) -> Episode {
        Episode(
            id: id, seriesID: seriesID, seasonID: seasonID, name: name,
            indexNumber: indexNumber, parentIndexNumber: parentIndexNumber,
            overview: overview, runtime: runtime, primaryTag: primaryTag,
            seasonImageRef: ref, seriesImageRef: seriesImageRef,
            dateAdded: dateAdded,
            userData: userData
        )
    }

    public func withSeriesImageRef(_ ref: ImageRef?) -> Episode {
        Episode(
            id: id, seriesID: seriesID, seasonID: seasonID, name: name,
            indexNumber: indexNumber, parentIndexNumber: parentIndexNumber,
            overview: overview, runtime: runtime, primaryTag: primaryTag,
            seasonImageRef: seasonImageRef, seriesImageRef: ref,
            dateAdded: dateAdded,
            userData: userData
        )
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        // Switch (not guard case) so the compiler errors if ImageKind
        // gains a new case — Episode would otherwise silently eat it.
        switch kind {
        case .primary:
            guard let tag = primaryTag else { return nil }
            return ImageRef(itemID: id, kind: .primary, tag: tag)
        case .backdrop, .logo, .thumb, .banner, .art, .disc:
            return nil
        }
    }
}

public extension Episode {
    /// Season/episode label, e.g. "S1, E2" — nil when either index is unknown.
    var seasonEpisodeLabel: String? {
        guard let season = parentIndexNumber, let index = indexNumber else { return nil }
        return "S\(season), E\(index)"
    }

    /// Whole-minute runtime for shelf captions, e.g. Next Up's `"S1, E2 · 45 min"`.
    var runtimeLengthMinutes: Int? {
        guard let runtime else { return nil }
        let minutes = Int(runtime.components.seconds / 60)
        return minutes > 0 ? minutes : nil
    }

    /// Shelf footer caption — episode index plus optional time metadata.
    /// In progress: `"S1, E2 · 22 min left"`. Unwatched / Next Up: `"S1, E2 · 45 min"`.
    func shelfFooterCaption(showTimeRemaining: Bool = true, showRuntimeLength: Bool = true) -> String? {
        var parts: [String] = []
        if let label = seasonEpisodeLabel {
            parts.append(label)
        } else if let index = indexNumber {
            parts.append("E\(index)")
        }
        if showTimeRemaining, userData.playbackPositionTicks > 0 {
            if let minutes = userData.remainingMinutes(runtime: runtime) {
                parts.append("\(minutes) min left")
            }
        } else if showRuntimeLength, let minutes = runtimeLengthMinutes {
            parts.append("\(minutes) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Playback fraction for shelf progress bars; nil when not started or runtime unknown.
    var shelfPlaybackProgress: Double? {
        guard userData.playbackPositionTicks > 0 else { return nil }
        let runtimeTicks = runtime.map { Int64($0.components.seconds) * 10_000_000 }
        return userData.playedFraction(runtimeTicks: runtimeTicks)
    }
}
