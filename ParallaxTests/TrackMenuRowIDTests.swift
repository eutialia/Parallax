import Testing
import ParallaxCore
import ParallaxPlayback
@testable import Parallax

/// Pins the row the panel scrolls to when a chip menu opens — and, on tvOS, focuses.
/// `leadingRowID` is that one row for every menu; audio alone needs a second resolver,
/// `focusableLeadingRowID`, because its undecodable rows are `.disabled` and the focus
/// engine can't land there. Those two agreeing whenever nothing is filtered is the point.
@Suite("Track menu leading row")
struct TrackMenuRowIDTests {

    // MARK: - Audio

    private static func audio(_ index: Int, unsupported: Bool = false) -> AudioTrack {
        AudioTrack(id: .jellyfinStream(index), displayName: "Track \(index)",
                   languageCode: "eng", isUnsupported: unsupported)
    }

    @Test("audio leads with the selected track")
    func audioSelected() {
        let tracks = [Self.audio(1), Self.audio(2), Self.audio(3)]
        #expect(AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: .jellyfinStream(2))
                == .track(.jellyfinStream(2)))
    }

    @Test("audio falls back to the first row when nothing matches")
    func audioFallsBackToFirst() {
        let tracks = [Self.audio(1), Self.audio(2)]
        #expect(AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: nil)
                == .track(.jellyfinStream(1)))
        #expect(AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: .jellyfinStream(99))
                == .track(.jellyfinStream(1)))
    }

    @Test("audio scrolls to an unsupported selection — dimming isn't hiding")
    func audioScrollsToUnsupported() {
        let tracks = [Self.audio(1), Self.audio(2, unsupported: true)]
        #expect(AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: .jellyfinStream(2))
                == .track(.jellyfinStream(2)))
    }

    @Test("audio focus skips unsupported rows (they aren't focusable)")
    func audioFocusSkipsUnsupported() {
        let tracks = [Self.audio(1, unsupported: true), Self.audio(2)]
        #expect(AudioTrackMenu.focusableLeadingRowID(tracks: tracks, selectedID: nil)
                == .track(.jellyfinStream(2)))
        // Selecting the unsupported row can't happen, but if the state ever says so,
        // focus still lands on a row the engine will accept.
        #expect(AudioTrackMenu.focusableLeadingRowID(tracks: tracks, selectedID: .jellyfinStream(1))
                == .track(.jellyfinStream(2)))
    }

    @Test("audio focus and scroll agree when every row is supported",
          arguments: [nil, TrackID.jellyfinStream(1), .jellyfinStream(2), .jellyfinStream(99)])
    func audioResolversAgree(selectedID: TrackID?) {
        let tracks = [Self.audio(1), Self.audio(2)]
        #expect(AudioTrackMenu.focusableLeadingRowID(tracks: tracks, selectedID: selectedID)
                == AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: selectedID))
    }

    @Test("every audio row unsupported: scroll still leads, focus has nowhere to go")
    func audioAllUnsupported() {
        let tracks = [Self.audio(1, unsupported: true), Self.audio(2, unsupported: true)]
        #expect(AudioTrackMenu.leadingRowID(tracks: tracks, selectedID: nil)
                == .track(.jellyfinStream(1)))
        #expect(AudioTrackMenu.focusableLeadingRowID(tracks: tracks, selectedID: nil) == nil)
    }

    @Test("no audio tracks yields no leading row")
    func audioEmpty() {
        #expect(AudioTrackMenu.leadingRowID(tracks: [], selectedID: nil) == nil)
        #expect(AudioTrackMenu.focusableLeadingRowID(tracks: [], selectedID: nil) == nil)
    }

    // MARK: - Subtitles

    private static func subtitle(_ index: Int) -> SubtitleTrack {
        SubtitleTrack(id: .jellyfinStream(index), displayName: "Track \(index)",
                      languageCode: "eng", isForced: false)
    }

    @Test("subtitles lead with the selected track")
    func subtitleSelected() {
        let tracks = [Self.subtitle(4), Self.subtitle(5)]
        #expect(SubtitleTrackMenu.leadingRowID(tracks: tracks, selectedID: .jellyfinStream(5))
                == .track(.jellyfinStream(5)))
    }

    @Test("subtitles off leads with the Off row", arguments: [nil, TrackID.jellyfinStream(99)])
    func subtitleOff(selectedID: TrackID?) {
        let tracks = [Self.subtitle(4), Self.subtitle(5)]
        #expect(SubtitleTrackMenu.leadingRowID(tracks: tracks, selectedID: selectedID) == .subtitlesOff)
        #expect(SubtitleTrackMenu.leadingRowID(tracks: [], selectedID: selectedID) == .subtitlesOff)
    }

    /// One resolver serves scroll and focus here (no row is unpickable), so what's left
    /// to pin is that it answers the selected row across the whole domain — Off included.
    @Test("subtitles resolve every selection to its own row",
          arguments: [nil, TrackID.jellyfinStream(4), .jellyfinStream(5)])
    func subtitleResolversAgree(selectedID: TrackID?) {
        let tracks = [Self.subtitle(4), Self.subtitle(5)]
        let expected: TrackMenuRowID = selectedID.map { .track($0) } ?? .subtitlesOff
        #expect(SubtitleTrackMenu.leadingRowID(tracks: tracks, selectedID: selectedID) == expected)
    }

    // MARK: - Speed

    private static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @Test("speed leads with the active rate", arguments: TrackMenuRowIDTests.rates)
    func speedSelected(rate: Double) {
        #expect(SpeedMenu.leadingRowID(options: Self.rates, selected: rate) == .rate(rate))
    }

    @Test("an off-menu rate falls back to the first option")
    func speedUnlistedRate() {
        #expect(SpeedMenu.leadingRowID(options: Self.rates, selected: 3.0) == .rate(0.5))
        #expect(SpeedMenu.leadingRowID(options: [], selected: 1.0) == nil)
    }

    // MARK: - Chapters

    private static let chapters = [
        Chapter(index: 0, name: "Opening", start: .seconds(0)),
        Chapter(index: 1, name: "Middle", start: .seconds(300)),
        Chapter(index: 2, name: "Finale", start: .seconds(900)),
    ]

    @Test("chapters lead with the one holding the playhead",
          arguments: [(-10.0, 0), (0.0, 0), (299.0, 0), (300.0, 1), (450.0, 1),
                      (900.0, 2), (100_000.0, 2)])
    func chapterAtPlayhead(seconds: Double, expected: Int) {
        #expect(PlayerViewModel.chapter(in: Self.chapters, atSeconds: seconds)?.id == expected)
    }

    @Test("no chapters yields no leading row")
    func chaptersEmpty() {
        #expect(PlayerViewModel.chapter(in: [], atSeconds: 12) == nil)
        #expect(PlayerViewModel.chapter(in: [], atSeconds: .nan) == nil)
    }

    /// The leading row and the highlighted row are one rule: a fractional start counts
    /// from its sub-second offset, and nothing before the first start is "no chapter".
    @Test("the chapter holding a position is the last one started at or before it",
          arguments: [(-1.0, 0), (299.9, 0), (300.0, 1), (300.5, 1), (899.99, 1), (900.0, 2)])
    func chapterAtPosition(seconds: Double, expected: Int) {
        let chapters = [
            Chapter(index: 0, name: nil, start: .seconds(0)),
            Chapter(index: 1, name: nil, start: .seconds(300)),
            Chapter(index: 2, name: nil, start: .milliseconds(900_000)),
        ]
        #expect(PlayerViewModel.chapter(in: chapters, atSeconds: seconds)?.index == expected)
    }

    /// `CMTimeGetSeconds(kCMTimeInvalid)` is NaN — what the engine reports before the
    /// first frame — and `Duration.seconds(_:)` TRAPS on a non-finite Double. The
    /// resolver runs on iOS too now, so this is a crash, not a wrong row.
    @Test("a non-finite playhead leads with the first chapter, not a trap",
          arguments: [Double.nan, .infinity, -.infinity])
    func chapterNonFinitePlayhead(seconds: Double) {
        #expect(PlayerViewModel.chapter(in: Self.chapters, atSeconds: seconds)?.id == 0)
    }

    // MARK: - Cross-menu identity

    /// The four key schemes share ONE id type, so a rate, a chapter index, a stream id
    /// and the Off sentinel must never collide — `scrollTargetLayout` resolves rows by
    /// this value alone.
    @Test("row ids stay distinct across cases")
    func rowIDsDistinctAcrossCases() {
        let ids: Set<TrackMenuRowID> = [.chapter(1), .rate(1.0), .track(.jellyfinStream(1)), .subtitlesOff]
        #expect(ids.count == 4)
    }
}
