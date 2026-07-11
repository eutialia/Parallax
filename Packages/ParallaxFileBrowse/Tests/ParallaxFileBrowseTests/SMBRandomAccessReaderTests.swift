import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBRandomAccessReader")
struct SMBRandomAccessReaderTests {

    /// After `disconnect()` the reader is permanently closed: a straggler `read` (an HTTP-bridge
    /// serve loop that raced the teardown) must throw immediately instead of lazily REconnecting
    /// a fresh SMB session nothing would tear down. Prompt failure (vs. the 15s connect timeout
    /// a reconnect attempt would burn against this unroutable host) proves no connect happened.
    @Test("read after disconnect throws instead of reconnecting")
    func readAfterDisconnectThrows() async {
        let reader = SMBRandomAccessReader(
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
