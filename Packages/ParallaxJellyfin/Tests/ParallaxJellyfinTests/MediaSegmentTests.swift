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

    /// A segment the playhead can never fall inside is worse than no segment: the player would
    /// draw a Skip affordance that never triggers. Each unusable tick combination reports
    /// separately so one failure can't mask another.
    @Test(
        "Unusable tick combinations map to nil",
        arguments: [
            (nil, nil, "neither bound"),
            (0 as Int?, nil as Int?, "no end"),
            (nil, 900, "no start"),
            (900, 100, "inverted — a half-open [start, end) that can never contain a playhead"),
            (500, 500, "zero length"),
        ] as [(Int?, Int?, String)]
    )
    func unusableSpansMapToNil(startTicks: Int?, endTicks: Int?, reason: String) {
        let dto = MediaSegmentDto(endTicks: endTicks, id: "x", itemID: "i", startTicks: startTicks, type: .intro)
        #expect(dto.toMediaSegment() == nil, "\(reason) must be dropped")
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
