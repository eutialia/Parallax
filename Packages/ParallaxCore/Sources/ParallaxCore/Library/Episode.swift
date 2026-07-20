import Foundation

public struct Episode: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let seriesID: ItemID
    public let seasonID: ItemID
    public let name: String
    /// Owning series title (e.g. "Breaking Bad") — episode names rarely identify the show on
    /// their own, so cross-series surfaces (search) render this alongside the episode name.
    public let seriesName: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?   // season number
    public let overview: String?
    public let runtime: Duration?
    public let primaryTag: ImageTag?
    /// Season folder art from Jellyfin's parent-primary fields (e.g. `season.jpg`).
    /// `var` only for the `with*` copies below; immutable to callers.
    public private(set) var seasonImageRef: ImageRef?
    /// Series poster when season art is missing (DTO hint or repository fetch).
    public private(set) var seriesImageRef: ImageRef?
    public let dateAdded: Date?
    /// `var` only for the `withUserData` copy below; immutable to callers.
    public private(set) var userData: UserItemData
    /// BlurHash per image, keyed by the image TAG (unique per image on the server), so an
    /// `imageRef(.primary)` can hand its decoded blur to the placeholder. Only the episode's
    /// OWN images live here — the season/series fallback refs carry a parent item's images, whose
    /// hashes aren't on this DTO, so those refs stay hash-less until fetched with their parent.
    public let blurHashes: [ImageTag: String]

    public init(
        id: ItemID, seriesID: ItemID, seasonID: ItemID, name: String,
        seriesName: String?,
        indexNumber: Int?, parentIndexNumber: Int?,
        overview: String?, runtime: Duration?,
        primaryTag: ImageTag?, seasonImageRef: ImageRef? = nil,
        seriesImageRef: ImageRef? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData,
        blurHashes: [ImageTag: String] = [:]
    ) {
        self.id = id; self.seriesID = seriesID; self.seasonID = seasonID
        self.name = name; self.seriesName = seriesName; self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.overview = overview; self.runtime = runtime
        self.primaryTag = primaryTag; self.seasonImageRef = seasonImageRef
        self.seriesImageRef = seriesImageRef
        self.dateAdded = dateAdded
        self.userData = userData
        self.blurHashes = blurHashes
    }

    public func withSeasonImageRef(_ ref: ImageRef?) -> Episode {
        var copy = self; copy.seasonImageRef = ref; return copy
    }

    /// Same item, updated watch state. A mutated copy — NOT an init call listing every field,
    /// which silently zeroed any field someone forgot to thread through (blurHashes, once).
    public func withUserData(_ userData: UserItemData) -> Episode {
        var copy = self; copy.userData = userData; return copy
    }

    public func withSeriesImageRef(_ ref: ImageRef?) -> Episode {
        var copy = self; copy.seriesImageRef = ref; return copy
    }

    public func imageRef(_ kind: ImageKind) -> ImageRef? {
        // Switch (not guard case) so the compiler errors if ImageKind
        // gains a new case — Episode would otherwise silently eat it.
        switch kind {
        case .primary:
            guard let tag = primaryTag else { return nil }
            return ImageRef(itemID: id, kind: .primary, tag: tag, blurHash: blurHashes[tag])
        case .backdrop, .logo, .thumb, .banner, .art, .disc:
            return nil
        }
    }
}

public extension Episode {
    /// Season/episode label, e.g. "S1 · E2" — nil when either index is unknown.
    var seasonEpisodeLabel: String? {
        guard let season = parentIndexNumber, let index = indexNumber else { return nil }
        return "S\(season) · E\(index)"
    }

    /// Whole-minute runtime for shelf captions, e.g. Next Up's `"S1 · E2 · 45 min"`.
    var runtimeLengthMinutes: Int? {
        guard let runtime else { return nil }
        let minutes = Int(runtime.components.seconds / 60)
        return minutes > 0 ? minutes : nil
    }

    /// Episode index caption — `"S1 · E2"`, degrading to `"E2"` when the season is unknown;
    /// nil when the episode index is too.
    var indexCaption: String? {
        seasonEpisodeLabel ?? indexNumber.map { "E\($0)" }
    }

    /// Time caption — `"22 min left"` while mid-watch, `"45 min"` otherwise; nil when the
    /// relevant duration is unknown or both facets are opted out. A played episode never
    /// reports time left, even when the server left stale position ticks behind — that
    /// would contradict the watched check the same surfaces draw.
    func timeCaption(showTimeRemaining: Bool = true, showRuntimeLength: Bool = true) -> String? {
        if showTimeRemaining, userData.isInProgress {
            return userData.remainingMinutes(runtime: runtime).map { "\($0) min left" }
        }
        if showRuntimeLength, let minutes = runtimeLengthMinutes {
            return "\(minutes) min"
        }
        return nil
    }

    /// Below-tile title for same-series surfaces (season rows): `"E3 · The One With the Embryos"`.
    /// Index first so truncation eats the name, never the position; falls back to the bare name
    /// when no index exists. Middle-dot per the app-wide caption convention. Mirrors
    /// `seriesContextCaption`'s part-dropping so a missing index never leaves a dangling separator.
    var indexedNameCaption: String {
        let parts = [indexCaption, name].compactMap(\.self).filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    /// Cross-series identity caption — `"S1 · E2 · Breaking Bad"`. Index first so tail
    /// truncation in a tight row eats the show name, never the episode index; empty or
    /// missing parts drop out cleanly (an orphaned episode with a blank SeriesName must
    /// not render a dangling separator). Nil when nothing identifies the episode.
    var seriesContextCaption: String? {
        let parts = [indexCaption, seriesName].compactMap(\.self).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Landscape-tile artwork for cross-series surfaces (search): the episode's own 16:9
    /// still when scraped, else season art, else series art — a parent poster center-crops
    /// in a landscape frame, which beats an empty placeholder. Home shelves use the
    /// reverse, poster-first order (`Item.homeShelfImageRef` in the app target).
    var stillFirstImageRef: ImageRef? {
        imageRef(.primary) ?? seasonImageRef ?? seriesImageRef
    }

    /// Shelf footer caption — episode index plus optional time metadata.
    /// In progress: `"S1 · E2 · 22 min left"`. Unwatched / Next Up: `"S1 · E2 · 45 min"`.
    func shelfFooterCaption(showTimeRemaining: Bool = true, showRuntimeLength: Bool = true) -> String? {
        let parts = [
            indexCaption,
            timeCaption(showTimeRemaining: showTimeRemaining, showRuntimeLength: showRuntimeLength),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Playback fraction for shelf progress bars; nil when not started, runtime unknown, or the
    /// episode is played — the server can leave stale position ticks behind on a played episode,
    /// and a partial bar would contradict the watched check the same surfaces draw (the same guard
    /// `timeCaption` applies to "min left").
    var shelfPlaybackProgress: Double? {
        guard !userData.played else { return nil }
        return userData.playedFraction(runtime: runtime)
    }
}
