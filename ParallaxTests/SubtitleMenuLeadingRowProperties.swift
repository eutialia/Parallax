import Testing
import ParallaxPlayback
@testable import Parallax

/// The row the subtitle menu opens on, and on tvOS focuses. The menu draws Off and then one
/// row per track.
@Suite("Subtitle menu leading row")
struct SubtitleMenuLeadingRowProperties {

    private static let cases = 500

    private static func id(_ random: inout SeededGenerator) -> TrackID {
        let index = Int.random(in: 0..<12, using: &random)
        return Bool.random(using: &random) ? .jellyfinStream(index) : .avKitOption(index)
    }

    @Test("the subtitle menu opens on the selected track when the menu lists it, else on Off, and always on a row it draws")
    func opensOnTheSelectedRow() {
        var random = SeededGenerator(seed: 0x6F_6666)
        for run in 0..<Self.cases {
            let ids = Array(Set((0..<Int.random(in: 0...6, using: &random)).map { _ in Self.id(&random) }))
            let tracks = ids.map { SubtitleTrack(id: $0, displayName: "Track", languageCode: "eng", isForced: false) }
            let selected: TrackID? = switch Int.random(in: 0..<3, using: &random) {
            case 0: nil
            case 1: ids.randomElement(using: &random)
            default: Self.id(&random)
            }
            let drawn = Set([TrackMenuRowID.subtitlesOff] + ids.map { .track($0) })

            let leading = SubtitleTrackMenu.leadingRowID(tracks: tracks, selectedID: selected)

            #expect(drawn.contains(leading), "run \(run): \(leading) of \(ids)")
            let listed = selected.flatMap { ids.contains($0) ? TrackMenuRowID.track($0) : nil }
            #expect(leading == listed ?? .subtitlesOff, "run \(run): \(String(describing: selected)) in \(ids)")
        }
    }
}
