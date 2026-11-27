import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// Where the silence in front of a late copied audio track goes, over tracks that start up to
/// two seconds before or after the first picture, in frames of 256 to 4096 samples, on a clock
/// that starts at zero.
@Suite("Leading silence")
struct LeadingSilenceProperties {
    @Test("silence is whole frames from zero on that end at the track's first frame and cover the first picture, and none when the track starts with the picture")
    func silenceCoversTheFirstPicture() {
        var random = SeededGenerator(seed: 0x6C65_6164)
        for run in 0..<500 {
            let picture = Int64.random(in: 0...192_000, using: &random)
            let first = max(0, picture + .random(in: -96_000...96_000, using: &random))
            let length = Int64.random(in: 256...4096, using: &random)
            let starts = LeadingSilence.starts(from: picture, to: first, frameLength: length)

            #expect(starts.isEmpty == (first <= picture || first < length), "run \(run)")
            #expect(zip(starts, starts.dropFirst() + [first]).allSatisfy { $1 - $0 == length }, "run \(run)")
            if let earliest = starts.first {
                #expect(earliest >= 0 && (earliest <= picture || earliest < length), "run \(run): \(earliest) for \(picture)")
                #expect(picture < earliest + length, "run \(run): \(earliest) for \(picture)")
            }
        }
    }
}
