import CoreMedia
import ParallaxCoreTestSupport
import ParallaxPlayback
import Testing
@testable import ParallaxFeatures

@MainActor
@Suite("What a reload is owed")
struct PendingReloadProperties {

    private static let cases = 500

    private enum Step {
        case seek(Double)
        case audio(Int)
        case subtitle(Int?)
        /// The server declined the burn-in the standing subtitle change went back from.
        case declined
    }

    private static func audio(_ index: Int) -> AudioTrack {
        AudioTrack(id: .jellyfinStream(index), displayName: "Audio \(index)", languageCode: "eng")
    }

    private static func subtitle(_ index: Int) -> SubtitleTrack {
        SubtitleTrack(id: .jellyfinStream(index), displayName: "Sub \(index)", languageCode: "eng", isForced: false)
    }

    private static func steps(_ random: inout SeededGenerator) -> [Step] {
        (0..<Int.random(in: 0...12, using: &random)).map { _ in
            switch Int.random(in: 0..<7, using: &random) {
            case 0, 1: .seek(Double(Int.random(in: 0...9000, using: &random)))
            case 2, 3: .audio(Int.random(in: 1...4, using: &random))
            case 4: .subtitle(nil)
            case 5: .subtitle(Int.random(in: 5...8, using: &random))
            default: .declined
            }
        }
    }

    /// Picks arrive the way the player sends them: each names what the menu showed just before it.
    @Test("each of position, audio and subtitle ends on its newest pick, remembers what stood before its first, and ignores the other two")
    func newestPickOldestPrevious() {
        var random = SeededGenerator(seed: 0x72_656C)
        for run in 0..<Self.cases {
            let steps = Self.steps(&random)
            let standingAudio = Self.audio(0), standingSubtitle = Self.subtitle(9)
            var shownAudio = standingAudio
            var shownSubtitle: SubtitleTrack? = standingSubtitle
            var record: PlayerViewModel.TrackSwitchFailure?
            var owed = PendingReload()

            for step in steps {
                switch step {
                case .seek(let seconds):
                    owed.merge(position: CMTime(seconds: seconds, preferredTimescale: 600))
                case .audio(let index):
                    owed.merge(audio: Self.audio(index), previous: shownAudio)
                    shownAudio = Self.audio(index)
                case .subtitle(let index):
                    owed.merge(subtitle: index.map(Self.subtitle), previous: shownSubtitle)
                    shownSubtitle = index.map(Self.subtitle)
                    record = nil
                case .declined:
                    guard owed.subtitle != nil else { continue }
                    record = .init(declined: Self.subtitle(7), fallback: shownSubtitle)
                    owed.subtitle?.reportOnLand = record
                }
            }

            let seeks = steps.compactMap { if case .seek(let seconds) = $0 { seconds } else { nil } }
            let audioPicks = steps.compactMap { if case .audio(let index) = $0 { index } else { nil } }
            let subtitlePicks = steps.compactMap { if case .subtitle(let index) = $0 { Optional(index) } else { nil } }
            let context: Comment = "run \(run): \(steps)"
            #expect(owed.position.map(CMTimeGetSeconds) == seeks.last, context)
            #expect(owed.audio == audioPicks.last.map {
                PendingReload.AudioChange(pick: Self.audio($0), previous: standingAudio)
            }, context)
            #expect(owed.subtitle == subtitlePicks.last.map {
                PendingReload.SubtitleChange(pick: $0.map(Self.subtitle), previous: standingSubtitle, reportOnLand: record)
            }, context)
            #expect(owed.changesTracks == !(audioPicks.isEmpty && subtitlePicks.isEmpty), context)
        }
    }
}
