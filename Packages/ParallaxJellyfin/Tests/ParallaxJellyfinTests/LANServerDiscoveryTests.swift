import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("LANServerDiscovery wire format")
struct LANServerDiscoveryTests {
    private static func payload(address: String = "http://192.168.1.10:8096", id: String = "abc", name: String = "Den") -> Data {
        Data(#"{"Address":"\#(address)","Id":"\#(id)","Name":"\#(name)"}"#.utf8)
    }

    @Test("Parses a well-formed Jellyfin discovery response")
    func parsesWellFormed() throws {
        let server = try #require(LANServerDiscovery.parseResponse(Self.payload(id: "abc123", name: "Living Room")))
        #expect(server.id == "abc123")
        #expect(server.name == "Living Room")
        #expect(server.address == URL(string: "http://192.168.1.10:8096"))
    }

    /// Anything on a broadcast port can answer, so every malformed shape has to be rejected rather
    /// than surfaced as a server entry the user can't actually connect to.
    @Test(
        "Unusable responses are rejected",
        arguments: [
            (Data([0xFF, 0xFE, 0x00, 0x01]), "not JSON at all"),
            (Data(#"{"Address":"http://192.168.1.10:8096","Id":"abc123"}"#.utf8), "missing the required Name"),
            (Data(#"{"Id":"abc","Name":"x"}"#.utf8), "missing the required Address"),
            (Self.payload(address: "not a url at all"), "an Address with no host"),
            (Data("".utf8), "an empty payload"),
        ] as [(Data, String)]
    )
    func rejectsUnusableResponses(payload: Data, reason: String) {
        #expect(LANServerDiscovery.parseResponse(payload) == nil, "\(reason) must be rejected")
    }
}

/// The retry/dedupe driver, exercised through the injected broadcaster only — no sockets, and no
/// wall-clock waiting: the suite awaits the discovery task itself rather than polling
/// `isDiscovering`, which is what made this timing-dependent before.
@Suite("LANServerDiscovery retry driver")
@MainActor
struct LANServerDiscoveryDriverTests {
    private let payload = Data(#"{"Address":"http://192.168.1.10:8096","Id":"abc","Name":"Den"}"#.utf8)

    private func discovery(_ batches: [[Data]]) -> (LANServerDiscovery, ScriptedBroadcaster) {
        let scripted = ScriptedBroadcaster(batches)
        return (LANServerDiscovery(broadcaster: { scripted($0) }), scripted)
    }

    /// The reason retries exist: iOS keeps the app active through the Local Network permission
    /// alert and exposes no authorization status, so the only way to notice a late grant is to
    /// broadcast again. Passes stop the moment something answers.
    @Test("Discovery re-broadcasts across empty passes, stops on the first hit, and dedupes")
    func retriesUntilServerFound() async {
        // Two empty passes (permission not yet granted), then the server answers on the third —
        // and would answer again on a fourth that must NOT run.
        let (discovery, scripted) = discovery([[], [], [payload], [payload]])

        discovery.start(timeout: 0, retries: 5, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(discovery.isDiscovering == false)
        #expect(discovery.discovered.map(\.id) == ["abc"])
        #expect(scripted.calls == 3, "passes 4 and 5 must never run once a server answered")
    }

    /// Retries are bounded: a network with no Jellyfin must not broadcast forever.
    @Test("With no server found, exactly retries + 1 passes run")
    func exhaustsRetries() async {
        let (discovery, scripted) = discovery([])

        discovery.start(timeout: 0, retries: 2, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(scripted.calls == 3)
        #expect(discovery.discovered.isEmpty)
        #expect(discovery.isDiscovering == false)
    }

    /// One pass can carry several answers, and repeated ids across passes are the same server —
    /// the seen-set is what keeps the picker from listing a server twice.
    @Test("Duplicate ids collapse while distinct servers all survive, in arrival order")
    func dedupesWithinAndAcrossPasses() async {
        let second = Data(#"{"Address":"http://192.168.1.11:8096","Id":"def","Name":"Attic"}"#.utf8)
        let (discovery, _) = discovery([[payload, second, payload]])

        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(discovery.discovered.map(\.id) == ["abc", "def"])
    }

    /// Unparseable answers must not stop the pass or count as a find.
    @Test("Garbage on the port doesn't count as a discovered server")
    func garbageDoesNotCountAsAFind() async {
        let (discovery, scripted) = discovery([[Data([0x00, 0x01])], [payload]])

        discovery.start(timeout: 0, retries: 1, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(scripted.calls == 2, "an unusable answer is not a find, so the retry still runs")
        #expect(discovery.discovered.map(\.id) == ["abc"])
    }

    /// A second `start()` while a run is in flight must be a no-op — the launch screen and the
    /// add-server sheet can both ask, and a doubled broadcast would double the passes.
    @Test("start() is idempotent while a run is in flight")
    func startIsIdempotent() async {
        let (discovery, scripted) = discovery([[payload]])

        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(scripted.calls == 1)
    }

    /// A finished run leaves the object reusable, and a fresh run is ADDITIVE — a server found
    /// earlier must not disappear from the list because the second pass didn't see it.
    @Test("A run after one finishes is additive")
    func laterRunIsAdditive() async {
        let second = Data(#"{"Address":"http://192.168.1.11:8096","Id":"def","Name":"Attic"}"#.utf8)
        let (discovery, _) = discovery([[payload], [second]])

        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        await discovery.runningTask?.value
        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        await discovery.runningTask?.value

        #expect(discovery.discovered.map(\.id) == ["abc", "def"])
    }

    @Test("stop() clears the in-flight state so a later run can start")
    func stopClearsState() async {
        let (discovery, _) = discovery([[payload]])

        discovery.start(timeout: 0, retries: 0, retryInterval: .zero)
        discovery.stop()

        #expect(discovery.isDiscovering == false)
        #expect(discovery.runningTask == nil)
    }
}

/// Deterministic broadcast source: hands back the scripted payload batches in order (then empties),
/// counting passes. `@unchecked Sendable` + a lock because the discovery driver invokes it off the
/// main actor.
private final class ScriptedBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[Data]]
    private var callCount = 0

    init(_ batches: [[Data]]) { self.batches = batches }

    var calls: Int { lock.withLock { callCount } }

    func callAsFunction(_ timeout: TimeInterval) -> [Data] {
        lock.withLock {
            callCount += 1
            return batches.isEmpty ? [] : batches.removeFirst()
        }
    }
}
