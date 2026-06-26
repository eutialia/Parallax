import Foundation

/// How one SMB browse level orders its entries. Unlike Jellyfin's `ItemSort` (release date,
/// rating, …), an SMB directory carries only what the filesystem records — a name and two
/// timestamps — so the field set is deliberately small. Folder/file partitioning is NOT part of
/// the sort: `SMBFileSource.browse` keeps folders in their own array, always above media, and this
/// only orders entries WITHIN a group.
public struct SMBBrowseSort: Sendable, Hashable {
    public enum Field: Sendable, Hashable, CaseIterable {
        case name
        case dateModified
        case dateCreated

        /// The order a field reads best in by default: names A→Z, dates newest-first. Picking a
        /// field adopts this so a carried-over direction can't silently flip meaning ("Newest" → "Z to A").
        public var naturalDirection: Direction {
            switch self {
            case .name: .ascending
            case .dateModified, .dateCreated: .descending
            }
        }
    }

    public enum Direction: Sendable, Hashable, CaseIterable {
        case ascending
        case descending
    }

    public var field: Field
    public var direction: Direction

    public init(field: Field, direction: Direction) {
        self.field = field
        self.direction = direction
    }

    /// Newest-created first — surfaces freshly-added media at the top of a share. A server that omits
    /// `createdAt` (no SMB `btime`) degrades gracefully: the comparator sorts those nil dates last and
    /// falls back to name A→Z, so the listing is never random.
    public static let `default` = SMBBrowseSort(field: .dateCreated, direction: .descending)
}

extension SMBBrowseSort {
    /// Orders entries by the selected field/direction. A missing timestamp is treated as unknown and
    /// always sorts LAST (in either direction) so dateless rows don't masquerade as the newest or
    /// oldest; equal keys fall back to name A→Z for a stable, predictable order.
    public func sorted(_ entries: [SMBDirectoryEntry]) -> [SMBDirectoryEntry] {
        entries.sorted(by: precedes)
    }

    private func precedes(_ a: SMBDirectoryEntry, _ b: SMBDirectoryEntry) -> Bool {
        switch field {
        case .name:
            return orderedByName(a, b)
        case .dateModified:
            return orderedByDate(a.modifiedAt, b.modifiedAt, a, b)
        case .dateCreated:
            return orderedByDate(a.createdAt, b.createdAt, a, b)
        }
    }

    private func orderedByName(_ a: SMBDirectoryEntry, _ b: SMBDirectoryEntry) -> Bool {
        let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
        guard cmp != .orderedSame else { return false }
        return direction == .ascending ? cmp == .orderedAscending : cmp == .orderedDescending
    }

    private func orderedByDate(_ lhs: Date?, _ rhs: Date?, _ a: SMBDirectoryEntry, _ b: SMBDirectoryEntry) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?):
            guard l != r else { return nameAscending(a, b) }   // tie-break by name
            return direction == .ascending ? l < r : l > r
        case (.some, .none):
            return true                                         // known date before unknown
        case (.none, .some):
            return false                                        // unknown after known
        case (.none, .none):
            return nameAscending(a, b)
        }
    }

    private func nameAscending(_ a: SMBDirectoryEntry, _ b: SMBDirectoryEntry) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
