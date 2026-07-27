import Foundation

/// One server's cached Home feed. The source tag the aggregated surfaces put on these items is
/// re-applied on read (it carries a live `Session`, which is never persisted), so only the
/// source-agnostic models are stored.
public struct HomeFeedSnapshot: Codable, Hashable, Sendable {
    public let hero: [HomeHeroFeedEntry]
    public let continueWatching: [Item]
    public let nextUp: [Item]

    public init(hero: [HomeHeroFeedEntry], continueWatching: [Item], nextUp: [Item]) {
        self.hero = hero
        self.continueWatching = continueWatching
        self.nextUp = nextUp
    }

    public var isEmpty: Bool { hero.isEmpty && continueWatching.isEmpty && nextUp.isEmpty }
}

/// Typed reads and writes over the generic store, so a caller can't pair a kind with the wrong
/// payload type (which would silently read back nil forever).
public extension SnapshotStore {
    func homeFeed(forServerID serverID: String) -> HomeFeedSnapshot? {
        load(HomeFeedSnapshot.self, kind: .homeFeed, serverID: serverID)
    }

    func setHomeFeed(_ snapshot: HomeFeedSnapshot, forServerID serverID: String) {
        save(snapshot, kind: .homeFeed, serverID: serverID)
    }

    func libraries(forServerID serverID: String) -> [MediaCollection]? {
        load([MediaCollection].self, kind: .libraries, serverID: serverID)
    }

    func setLibraries(_ collections: [MediaCollection], forServerID serverID: String) {
        save(collections, kind: .libraries, serverID: serverID)
    }

    /// Whether launch has a Home feed to open onto. Synchronous and decode-free — the launch gate
    /// reads it before any async work to choose between the full launch story and a micro-reveal.
    nonisolated var hasCachedHomeFeed: Bool { hasAnySnapshot(kind: .homeFeed) }
}
