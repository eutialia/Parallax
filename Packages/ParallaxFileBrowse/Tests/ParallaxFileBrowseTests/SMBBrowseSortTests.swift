import Foundation
import Testing
@testable import ParallaxFileBrowse

/// The comparator directly, at the level `SMBFileSource.browse` consumes it. `browse` owns the
/// folders-above-media partitioning; everything about ORDER lives here.
@Suite("SMBBrowseSort")
struct SMBBrowseSortTests {

    private static let older = Date(timeIntervalSince1970: 1_000)
    private static let newer = Date(timeIntervalSince1970: 9_000)

    /// Picking a field adopts its natural direction so a carried-over direction can't silently flip
    /// a control's meaning ("Newest" reading as "Z to A").
    @Test("every field reads best in its natural direction")
    func naturalDirectionPerField() {
        let expected: [SMBBrowseSort.Field: SMBBrowseSort.Direction] = [
            .name: .ascending,
            .dateModified: .descending,
            .dateCreated: .descending,
        ]
        // Driven off allCases, so a newly added field fails here (nil expectation) instead of
        // silently inheriting whatever the switch falls into.
        for field in SMBBrowseSort.Field.allCases {
            #expect(field.naturalDirection == expected[field], "unexpected natural direction for \(field)")
        }
    }

    @Test("the default sort is newest-created first")
    func defaultIsNewestCreated() {
        #expect(SMBBrowseSort.default.field == .dateCreated)
        #expect(SMBBrowseSort.default.direction == SMBBrowseSort.Field.dateCreated.naturalDirection)
    }

    @Test("name sort is case-insensitive in both directions",
          arguments: [(SMBBrowseSort.Direction.ascending, ["alpha", "Beta", "gamma"]),
                      (.descending, ["gamma", "Beta", "alpha"])])
    func nameSortIsCaseInsensitive(_ direction: SMBBrowseSort.Direction, _ expected: [String]) {
        let entries = [SMBEntry.file("gamma"), SMBEntry.file("alpha"), SMBEntry.file("Beta")]
        let sorted = SMBBrowseSort(field: .name, direction: direction).sorted(entries)
        #expect(sorted.map(\.name) == expected)
    }

    @Test("equal names keep their relative order rather than swapping")
    func equalNamesDoNotSwap() {
        // Two entries whose names compare .orderedSame under case-insensitive collation: the
        // comparator must report "neither precedes the other", or sorting becomes unstable.
        let entries = [SMBEntry.file("Movie.mkv", size: 1), SMBEntry.file("movie.mkv", size: 2)]
        let sorted = SMBBrowseSort(field: .name, direction: .ascending).sorted(entries)
        #expect(sorted.map(\.size) == [1, 2])
    }

    @Test("date sorts read the field they name, not the other timestamp",
          arguments: [(SMBBrowseSort.Field.dateModified, SMBBrowseSort.Direction.descending, ["mtime-new", "mtime-old"]),
                      (.dateModified, .ascending, ["mtime-old", "mtime-new"]),
                      (.dateCreated, .descending, ["mtime-old", "mtime-new"]),
                      (.dateCreated, .ascending, ["mtime-new", "mtime-old"])])
    func dateSortsReadTheNamedField(
        _ field: SMBBrowseSort.Field,
        _ direction: SMBBrowseSort.Direction,
        _ expected: [String]
    ) {
        // btime order is the REVERSE of mtime order, so a comparator reading the wrong timestamp
        // produces the wrong answer instead of coincidentally the right one.
        let entries = [
            SMBEntry.file("mtime-new", modified: Self.newer, created: Self.older),
            SMBEntry.file("mtime-old", modified: Self.older, created: Self.newer),
        ]
        let sorted = SMBBrowseSort(field: field, direction: direction).sorted(entries)
        #expect(sorted.map(\.name) == expected)
    }

    /// A server that omits btime must degrade gracefully: dateless rows sort LAST in either
    /// direction (never masquerading as newest or oldest) and tie-break by name A→Z.
    @Test("entries with no date sort last and tie-break by name",
          arguments: [SMBBrowseSort.Direction.ascending, .descending])
    func missingDatesSortLastByName(_ direction: SMBBrowseSort.Direction) {
        let entries = [
            SMBEntry.file("zeta-undated"),
            SMBEntry.file("dated", modified: Self.newer),
            SMBEntry.file("alpha-undated"),
        ]
        let sorted = SMBBrowseSort(field: .dateModified, direction: direction).sorted(entries)
        #expect(sorted.map(\.name) == ["dated", "alpha-undated", "zeta-undated"])
    }

    @Test("entries sharing a timestamp tie-break by name A→Z in both directions",
          arguments: [SMBBrowseSort.Direction.ascending, .descending])
    func equalDatesTieBreakByName(_ direction: SMBBrowseSort.Direction) {
        let entries = [
            SMBEntry.file("zeta", modified: Self.newer),
            SMBEntry.file("alpha", modified: Self.newer),
        ]
        let sorted = SMBBrowseSort(field: .dateModified, direction: direction).sorted(entries)
        #expect(sorted.map(\.name) == ["alpha", "zeta"], "a date tie must never be direction-dependent")
    }
}
