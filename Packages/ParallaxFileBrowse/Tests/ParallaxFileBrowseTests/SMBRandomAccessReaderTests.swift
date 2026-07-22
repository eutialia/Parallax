import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBRandomAccessReader")
struct SMBRandomAccessReaderTests {

    /// After `disconnect()` the reader is permanently closed: a straggler `read` (an HTTP-bridge
    /// serve loop that raced the teardown) must throw immediately instead of lazily re-BORROWING
    /// a fresh pool connection nothing would check back in. Prompt failure (vs. the 15s connect
    /// timeout a checkout attempt would burn against this unroutable host) proves no checkout happened.
    /// `disconnect()` before any read leaves no borrow to check in, so the pool is never touched.
    @Test("read after disconnect throws instead of re-borrowing")
    func readAfterDisconnectThrows() async {
        let reader = SMBRandomAccessReader(
            pool: SMBSharePool(),
            host: "203.0.113.0", username: "u", password: "p",
            share: "share", path: "file.mp4"
        )
        await reader.disconnect()

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CancellationError.self) {
            _ = try await reader.read(offset: 0, length: 1)
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}
