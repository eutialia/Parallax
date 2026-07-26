import Testing
@testable import Parallax

/// Unit tests for `SMBBonjourDiscovery`'s pure mapping logic.
///
/// Live browsing (`NWBrowser`) requires a real network stack and cannot be exercised
/// headlessly — those paths are integration-only. The only thing this type owns that a unit
/// test can reach is `discoveredServer(forServiceName:)`, so that mapping is the whole suite.
/// (Dedup lives in the caller, not here; the tests that "proved" it were re-implementing the
/// filter inside the test body, and `id == name` makes distinct-ids tautological.)
@Suite("SMBBonjourDiscovery")
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
}
