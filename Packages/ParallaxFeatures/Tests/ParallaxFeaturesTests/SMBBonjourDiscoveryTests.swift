import Observation
import Synchronization
import Testing
import ParallaxTestScaling
@testable import ParallaxFeatures

/// Live browsing (`NWBrowser`) needs a real network stack, so the run lifecycle is driven through
/// the injected `browse` streams.
@Suite("SMBBonjourDiscovery", .scaledTimeLimit())
struct SMBBonjourDiscoveryTests {
    @Test(
        "a Bonjour service name maps verbatim to id/name, with .local appended for the host",
        arguments: [
            // (service name, expected host) — id and name are always the service name verbatim.
            ("MyNAS", "MyNAS.local"),
            // Spaces and punctuation must survive unescaped: `.local` resolution takes the
            // literal instance name, so any mangling here breaks the connect attempt.
            ("Alice's NAS", "Alice's NAS.local"),
            // The degenerate advertisement — mapped, not crashed, and left for the caller to reject.
            ("", ".local"),
        ]
    )
    func mapsServiceName(name: String, expectedHost: String) {
        let server = SMBBonjourDiscovery.discoveredServer(forServiceName: name)
        #expect(server.id == name)
        #expect(server.name == name)
        #expect(server.host == expectedHost)
    }

    /// Closing and reopening the picker stops one browse and starts the next; the stopped browse
    /// winds down after the new one is running, and that must not end the new one.
    @MainActor
    @Test("a stopped browse winding down late leaves the browse that replaced it running")
    func staleBrowseEndLeavesNewBrowse() async throws {
        let browses = Browses()
        let discovery = SMBBonjourDiscovery(browse: { browses.open() })
        discovery.start()
        discovery.stop()
        discovery.start()

        browses.latest(["NAS"])
        for await names in Observations({ discovery.discovered.map(\.name) }) where names == ["NAS"] { break }

        #expect(discovery.isDiscovering)
    }
}

private final class Browses: Sendable {
    private let continuations = Mutex<[AsyncStream<[String]>.Continuation]>([])

    func open() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func latest(_ names: [String]) {
        _ = continuations.withLock { $0.last }?.yield(names)
    }
}
