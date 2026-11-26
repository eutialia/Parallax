import Testing
@testable import ParallaxPlayback

/// `HLSPlaylist.distinct` over generated track names, drawn from a few that repeat and that
/// look like each other's numbered forms.
@Suite("HLSPlaylist — properties")
struct HLSPlaylistProperties {
    private static let pool = ["English", "English 2", "English 3", "English 2 2", "Japanese", "Japanese 2", "Commentary", ""]

    @Test("a repeated track name gets the lowest number no other track's name already has, and no other name changes")
    func repeatedNamesAreNumbered() {
        let seed = UInt64(0x6469_7374_696E)
        var random = SplitMix(seed: seed)
        for _ in 0..<500 {
            let names = (0..<Int.random(in: 0...10, using: &random)).map { _ in Self.pool.randomElement(using: &random)! }
            let distinct = HLSPlaylist.distinct(names)
            let context = "seed \(seed): \(names) gave \(distinct)"

            #expect(distinct.count == names.count, "\(context)")
            #expect(Set(distinct).count == distinct.count, "\(context)")
            for place in names.indices {
                let name = names[place]
                guard names[..<place].contains(name) else {
                    #expect(distinct[place] == name, "\(context)")
                    continue
                }
                let number = distinct[place].hasPrefix("\(name) ") ? Int(distinct[place].dropFirst(name.count + 1)) : nil
                #expect(number.map { $0 >= 2 } == true, "\(context)")
                for lower in 2..<max(number ?? 2, 2) {
                    #expect(distinct.enumerated().contains { $0.offset != place && $0.element == "\(name) \(lower)" }, "\(context)")
                }
            }
            #expect(HLSPlaylist.distinct(distinct) == distinct, "\(context)")
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
