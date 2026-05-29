import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("LANServerDiscovery wire format")
struct LANServerDiscoveryTests {
    @Test("Parses a well-formed Jellyfin discovery response")
    func parsesWellFormed() {
        let json = #"""
        {"Address":"http://192.168.1.10:8096","Id":"abc123","Name":"Living Room"}
        """#.data(using: .utf8)!

        let server = LANServerDiscovery.parseResponse(json)
        #expect(server?.id == "abc123")
        #expect(server?.name == "Living Room")
        #expect(server?.address == URL(string: "http://192.168.1.10:8096"))
    }

    @Test("Rejects malformed JSON")
    func rejectsGarbage() {
        let junk = Data([0xFF, 0xFE, 0x00, 0x01])
        #expect(LANServerDiscovery.parseResponse(junk) == nil)
    }

    @Test("Rejects responses with a missing required field")
    func rejectsMissingField() {
        let json = #"""
        {"Address":"http://192.168.1.10:8096","Id":"abc123"}
        """#.data(using: .utf8)!
        #expect(LANServerDiscovery.parseResponse(json) == nil)
    }

    @Test("Rejects responses whose address has no host")
    func rejectsHostlessAddress() {
        let json = #"""
        {"Address":"not a url at all","Id":"abc","Name":"x"}
        """#.data(using: .utf8)!
        #expect(LANServerDiscovery.parseResponse(json) == nil)
    }

    @Test("start(retries:) keeps scanning until a server appears, then stops; results dedupe")
    @MainActor
    func retriesUntilServerFound() async throws {
        let payload = #"""
        {"Address":"http://192.168.1.10:8096","Id":"abc","Name":"Den"}
        """#.data(using: .utf8)!
        // Two empty passes (permission not yet granted), then the server shows
        // up on the third (and would again on a fourth that must NOT run).
        let scripted = ScriptedBroadcaster([[], [], [payload], [payload]])
        let discovery = LANServerDiscovery(broadcaster: { scripted($0) })

        discovery.start(timeout: 0.01, retries: 5, retryInterval: .milliseconds(5))

        for _ in 0..<200 where discovery.isDiscovering {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(discovery.isDiscovering == false)
        #expect(discovery.discovered.count == 1)            // deduped despite two hits
        #expect(discovery.discovered.first?.id == "abc")
        #expect(scripted.calls == 3)                        // stopped on first hit; passes 4/5 never ran
    }
}

/// Deterministic broadcast source: hands back the scripted payload batches in
/// order (then empties), counting passes. `@unchecked Sendable` + a lock because
/// the discovery driver invokes it off the main actor.
private final class ScriptedBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[Data]]
    private var callCount = 0

    init(_ batches: [[Data]]) { self.batches = batches }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    func callAsFunction(_ timeout: TimeInterval) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}
