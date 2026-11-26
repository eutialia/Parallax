import Foundation
import Testing
import ParallaxCore

/// The share every delivery case reads through. A read past the end returns what the file
/// holds of it, as the SMB reader and POSIX `pread` do.
@Suite("InMemoryRandomAccessReader")
struct InMemoryRandomAccessReaderTests {

    @Test("a read returns the bytes of its range that the data holds, and nothing past its end")
    func readIsTheSliceItCovers() async throws {
        let seed: UInt64 = 0x1A3E_0001
        var random = SplitMixRandom(seed: seed)
        for index in 0..<300 {
            let data = Data((0..<Int.random(in: 0...64, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) })
            let offset = Int.random(in: 0...(data.count + 8), using: &random)
            let length = Int.random(in: 0...(data.count + 8), using: &random)

            let read = try await InMemoryRandomAccessReader(data: data).read(offset: UInt64(offset), length: length)

            let slice = data[min(offset, data.count)..<min(offset + length, data.count)]
            #expect(read == slice, "read \(index), offset \(offset), length \(length) of \(data.count), seed \(seed)")
        }
    }
}

/// A seeded generator, so a property's inputs are the same on every run.
private struct SplitMixRandom: RandomNumberGenerator {
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
