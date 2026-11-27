import Testing
@testable import ParallaxPlayback

/// Where the silence in front of a late copied audio track goes, over tracks that start up to
/// two seconds before or after the first picture, in frames of 256 to 4096 samples, on a clock
/// that starts at zero.
@Suite("Leading silence")
struct LeadingSilenceProperties {
    @Test("silence is whole frames from zero on that end at the track's first frame and cover the first picture, and none when the track starts with the picture")
    func silenceCoversTheFirstPicture() {
        var random = SplitMix(seed: 0x6C65_6164)
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

/// A seeded generator, so a property test's inputs are the same on every run.
private struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
