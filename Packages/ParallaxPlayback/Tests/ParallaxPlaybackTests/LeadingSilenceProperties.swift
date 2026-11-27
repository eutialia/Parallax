import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// How much silence goes in front of a late copied audio track, over tracks that start up to two
/// seconds before or after the first picture, in frames of 120 to 4608 samples at the rates real
/// files use.
@Suite("Leading silence")
struct LeadingSilenceProperties {
    @Test("silence is whole frames that reach back to the first picture with no frame to spare, and none when the track starts with the picture")
    func silenceCoversTheFirstPicture() {
        var random = SeededGenerator(seed: 0x6C65_6164)
        for run in 0..<500 {
            let picture = Int64.random(in: 0...4_000_000_000, using: &random)
            let first = max(0, picture + .random(in: -2_000_000_000...2_000_000_000, using: &random))
            let rate: Int64 = [8000, 22050, 44100, 48000, 96000].randomElement(using: &random)!
            let frame = Int64.random(in: 120...4608, using: &random)
            let length = LeadingSilence.length(from: picture, to: first, sampleRate: rate, frameLength: frame)
            let lead = Int128(first - picture) * Int128(rate)
            let context: Comment = "run \(run): \(length) ticks for \(first - picture) ns at \(rate) Hz in \(frame)"

            #expect(length % frame == 0, context)
            #expect((length == 0) == (first <= picture), context)
            if length > 0 {
                #expect(Int128(length) * 1_000_000_000 >= lead, context)
                #expect(Int128(length - frame) * 1_000_000_000 < lead, context)
            }
        }
    }
}
