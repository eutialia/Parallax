import Testing
import CoreMedia
@testable import Parallax
import ParallaxPlayback

/// The merge algebra of `PendingReload`, exercised without a view model: the value type is
/// what makes "actions during a reload compose" a rule rather than four call sites agreeing.
@MainActor
struct PendingReloadTests {

    private static func audio(_ index: Int) -> AudioTrack {
        AudioTrack(id: .jellyfinStream(index), displayName: "Audio \(index)", languageCode: "eng")
    }

    private static func subtitle(_ index: Int) -> SubtitleTrack {
        SubtitleTrack(id: .jellyfinStream(index), displayName: "Sub \(index)",
                      languageCode: "eng", isForced: false)
    }

    @Test("a fresh intent is empty, and any one dimension fills it")
    func emptinessTracksEveryDimension() {
        #expect(PendingReload().isEmpty)

        var seek = PendingReload()
        seek.merge(position: CMTime(seconds: 30, preferredTimescale: 600))
        #expect(!seek.isEmpty)

        var pick = PendingReload()
        pick.merge(audio: Self.audio(4), previous: nil)
        #expect(!pick.isEmpty)

        // Off is a real subtitle intent, not the absence of one.
        var off = PendingReload()
        off.merge(subtitle: nil, previous: Self.subtitle(1))
        #expect(!off.isEmpty)
    }

    @Test("the newest position wins", arguments: [[10.0, 20.0], [900.0, 30.0, 3_000.0]])
    func newestPositionWins(targets: [Double]) {
        var intent = PendingReload()
        for seconds in targets {
            intent.merge(position: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        #expect(CMTimeGetSeconds(intent.position ?? .invalid) == targets.last)
    }

    @Test("the newest audio pick wins and the OLDEST previous is kept",
          arguments: [[4], [4, 5], [5, 4, 5]])
    func newestAudioPickOldestPrevious(picks: [Int]) {
        var intent = PendingReload()
        let standing = Self.audio(3)
        // Every merge reports the selection VISIBLE at the time — which is the previous
        // pick after the first, exactly as the optimistic label leaves it.
        var visible: AudioTrack? = standing
        for index in picks {
            intent.merge(audio: Self.audio(index), previous: visible)
            visible = Self.audio(index)
        }
        #expect(intent.audio?.pick == Self.audio(picks.last!))
        #expect(intent.audio?.previous == standing)
    }

    @Test("the newest subtitle pick wins and the OLDEST previous is kept — Off included",
          arguments: [[1], [1, 7], [7, 1], [nil], [1, nil], [nil, 7]] as [[Int?]])
    func newestSubtitlePickOldestPrevious(picks: [Int?]) {
        var intent = PendingReload()
        let standing = Self.subtitle(2)
        var visible: SubtitleTrack? = standing
        for index in picks {
            let pick = index.map(Self.subtitle)
            intent.merge(subtitle: pick, previous: visible)
            visible = pick
        }
        #expect(intent.subtitle?.pick == picks.last!.map(Self.subtitle))
        #expect(intent.subtitle?.previous == standing)
    }

    @Test("the three dimensions never clobber each other")
    func dimensionsAreOrthogonal() {
        var intent = PendingReload()
        intent.merge(audio: Self.audio(4), previous: Self.audio(3))
        intent.merge(position: CMTime(seconds: 3_000, preferredTimescale: 600))
        intent.merge(subtitle: Self.subtitle(7), previous: nil)
        intent.merge(audio: Self.audio(5), previous: Self.audio(4))

        #expect(intent.audio?.pick == Self.audio(5))
        #expect(intent.audio?.previous == Self.audio(3))
        #expect(CMTimeGetSeconds(intent.position ?? .invalid) == 3_000)
        #expect(intent.subtitle?.pick == Self.subtitle(7))
        #expect(intent.subtitle?.previous == nil)
    }

    /// The record only the declined-burn-in rollback carries: it names a pick the user has
    /// already been answered about, so any newer pick of the same dimension drops it.
    @Test("a newer subtitle pick drops the record the standing change was carrying")
    func aNewerPickDropsTheRecordOnLand() {
        var intent = PendingReload()
        intent.merge(subtitle: Self.subtitle(1), previous: Self.subtitle(1))
        intent.subtitle?.reportOnLand = .init(declined: Self.subtitle(7), fallback: Self.subtitle(1))
        #expect(intent.subtitle?.reportOnLand != nil)

        intent.merge(subtitle: nil, previous: Self.subtitle(1))
        #expect(intent.subtitle?.reportOnLand == nil)
        #expect(intent.subtitle?.previous == Self.subtitle(1))
    }

    @Test("a seek merged into a standing pick leaves the pick untouched, and vice versa")
    func mergeOrderDoesNotMatter() {
        var seekFirst = PendingReload()
        seekFirst.merge(position: CMTime(seconds: 42, preferredTimescale: 600))
        seekFirst.merge(audio: Self.audio(4), previous: Self.audio(3))

        var pickFirst = PendingReload()
        pickFirst.merge(audio: Self.audio(4), previous: Self.audio(3))
        pickFirst.merge(position: CMTime(seconds: 42, preferredTimescale: 600))

        #expect(seekFirst == pickFirst)
    }
}
