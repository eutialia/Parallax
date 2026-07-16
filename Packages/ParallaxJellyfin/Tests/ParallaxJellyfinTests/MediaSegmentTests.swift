import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("Media segment mapping")
struct MediaSegmentMappingTests {
    @Test("DTO → MediaSegment maps 100-ns ticks to Duration and type to kind")
    func mapsDtoToSegment() throws {
        let dto = MediaSegmentDto(
            endTicks: 9_000_000_000,   // 900s in 100-ns ticks
            id: "seg1",
            itemID: "item1",
            startTicks: 0,
            type: .intro
        )
        let segment = try #require(dto.toMediaSegment())
        #expect(segment.id == "seg1")
        #expect(segment.kind == .intro)
        #expect(segment.start == .seconds(0))
        #expect(segment.end == .seconds(900))
    }

    @Test("Missing start/end ticks → nil (unusable segment)")
    func nilWhenMissingTicks() {
        let dto = MediaSegmentDto(endTicks: nil, id: "x", itemID: "i", startTicks: nil, type: .outro)
        #expect(dto.toMediaSegment() == nil)
    }

    @Test("Non-positive span (end <= start) → nil (unusable segment)")
    func nilWhenSpanNonPositive() {
        // Inverted: a half-open [start, end) range that can never contain a playhead.
        #expect(MediaSegmentDto(endTicks: 100, id: "x", itemID: "i", startTicks: 900, type: .intro).toMediaSegment() == nil)
        // Zero-length: start == end.
        #expect(MediaSegmentDto(endTicks: 500, id: "x", itemID: "i", startTicks: 500, type: .intro).toMediaSegment() == nil)
    }

    @Test("Absent/unknown type folds to .unknown, not dropped")
    func unknownType() throws {
        let dto = MediaSegmentDto(endTicks: 10, id: "x", itemID: "i", startTicks: 0, type: nil)
        let segment = try #require(dto.toMediaSegment())
        #expect(segment.kind == .unknown)
    }

    @Test("playerAction: intro/recap skip, outro advances, rest nil")
    func playerActions() {
        #expect(MediaSegmentKind.intro.playerAction == .skip)
        #expect(MediaSegmentKind.recap.playerAction == .skip)
        #expect(MediaSegmentKind.outro.playerAction == .nextEpisode)
        #expect(MediaSegmentKind.preview.playerAction == nil)
        #expect(MediaSegmentKind.commercial.playerAction == nil)
        #expect(MediaSegmentKind.unknown.playerAction == nil)
    }

    @Test("contains(seconds:) is half-open [start, end)")
    func containsHalfOpen() {
        let seg = MediaSegment(id: "s", kind: .intro, start: .seconds(10), end: .seconds(20))
        #expect(!seg.contains(seconds: 9))
        #expect(seg.contains(seconds: 10))      // start inclusive
        #expect(seg.contains(seconds: 15))
        #expect(!seg.contains(seconds: 20))     // end exclusive
        #expect(!seg.contains(seconds: 21))
        #expect(seg.startSeconds == 10)
        #expect(seg.endSeconds == 20)
    }
}

@Suite("Adjacent episodes")
struct AdjacentEpisodesTests {
    private func ep(_ id: String, s: Int, e: Int) -> Episode {
        Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: "series"),
            seasonID: ItemID(rawValue: "season\(s)"),
            name: "S\(s)E\(e)",
            seriesName: nil,
            indexNumber: e,
            parentIndexNumber: s,
            overview: nil,
            runtime: nil,
            primaryTag: nil,
            userData: .absent
        )
    }

    @Test("Middle of a 3-item window → both neighbors")
    func middle() {
        let window = [ep("a", s: 1, e: 1), ep("b", s: 1, e: 2), ep("c", s: 1, e: 3)]
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "b"), in: window)
        #expect(adj.previous?.id == ItemID(rawValue: "a"))
        #expect(adj.next?.id == ItemID(rawValue: "c"))
    }

    @Test("First episode → next only (2-item boundary window)")
    func firstEpisode() {
        let window = [ep("a", s: 1, e: 1), ep("b", s: 1, e: 2)]
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "a"), in: window)
        #expect(adj.previous == nil)
        #expect(adj.next?.id == ItemID(rawValue: "b"))
    }

    @Test("Last episode → previous only (2-item boundary window)")
    func lastEpisode() {
        let window = [ep("a", s: 2, e: 9), ep("b", s: 2, e: 10)]
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "b"), in: window)
        #expect(adj.previous?.id == ItemID(rawValue: "a"))
        #expect(adj.next == nil)
    }

    @Test("Solo episode → no neighbors")
    func solo() {
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "a"), in: [ep("a", s: 1, e: 1)])
        #expect(adj == .none)
    }

    @Test("Queried episode absent from window → none (defensive)")
    func notFound() {
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "z"), in: [ep("a", s: 1, e: 1)])
        #expect(adj == .none)
    }

    @Test("Cross-season window → S2E1 is next after the S1 finale")
    func crossSeason() {
        let window = [ep("a", s: 1, e: 10), ep("b", s: 1, e: 11), ep("c", s: 2, e: 1)]
        let adj = AdjacentEpisodes(around: ItemID(rawValue: "b"), in: window)
        #expect(adj.next?.id == ItemID(rawValue: "c"))
        #expect(adj.next?.parentIndexNumber == 2)
    }
}
