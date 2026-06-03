import Foundation

/// A chapter marker on a playable item (Jellyfin `ChapterInfo`). `start` is the
/// chapter's offset from the item start. Name is optional — Jellyfin auto-names
/// unnamed chapters "Chapter N" server-side, but we keep it optional and let the UI
/// fall back so we don't assume.
public struct Chapter: Sendable, Hashable, Identifiable {
    public let index: Int
    public let name: String?
    public let start: Duration

    public var id: Int { index }

    public init(index: Int, name: String?, start: Duration) {
        self.index = index
        self.name = name
        self.start = start
    }
}
