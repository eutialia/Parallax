import Testing
@testable import Parallax

/// Unit tests for `SMBBonjourDiscovery`'s pure mapping logic.
///
/// Live browsing (`NWBrowser`) requires a real network stack and cannot be
/// exercised headlessly — those paths are integration-only. Only the pure
/// static mapping function and deduplication logic are covered here.
@Suite("SMBBonjourDiscovery")
struct SMBBonjourDiscoveryTests {

    // MARK: - discoveredServer(forServiceName:)

    @Test("maps service name to correct id, name, and .local host")
    func mapsServiceName() {
        let server = SMBBonjourDiscovery.discoveredServer(forServiceName: "MyNAS")
        #expect(server.id == "MyNAS")
        #expect(server.name == "MyNAS")
        #expect(server.host == "MyNAS.local")
    }

    @Test("preserves names with spaces and punctuation unchanged")
    func preservesSpecialCharacters() {
        let server = SMBBonjourDiscovery.discoveredServer(forServiceName: "Alice's NAS")
        #expect(server.id == "Alice's NAS")
        #expect(server.name == "Alice's NAS")
        #expect(server.host == "Alice's NAS.local")
    }

    @Test("empty string service name produces empty id and name with .local host")
    func emptyServiceName() {
        let server = SMBBonjourDiscovery.discoveredServer(forServiceName: "")
        #expect(server.id == "")
        #expect(server.name == "")
        #expect(server.host == ".local")
    }

    // MARK: - Deduplication

    @Test("mapping multiple distinct names produces no duplicate ids")
    func noDuplicateIDs() {
        let names = ["NAS-1", "NAS-2", "NAS-3"]
        let servers = names.map { SMBBonjourDiscovery.discoveredServer(forServiceName: $0) }
        let ids = servers.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("mapping the same name twice yields equal servers")
    func sameMappingProducesEqualServers() {
        let a = SMBBonjourDiscovery.discoveredServer(forServiceName: "SharedDrive")
        let b = SMBBonjourDiscovery.discoveredServer(forServiceName: "SharedDrive")
        #expect(a == b)
    }

    @Test("deduping a list with a repeated service name leaves one entry")
    func dedupeByID() {
        let names = ["NAS-1", "NAS-2", "NAS-1", "NAS-3", "NAS-2"]
        let servers = names.map { SMBBonjourDiscovery.discoveredServer(forServiceName: $0) }

        var seen = Set<String>()
        let deduped = servers.filter { seen.insert($0.id).inserted }

        #expect(deduped.count == 3)
        #expect(deduped.map(\.id) == ["NAS-1", "NAS-2", "NAS-3"])
    }

    // MARK: - Identifiable / Hashable conformance

    @Test("SMBDiscoveredServer is Hashable and can live in a Set")
    func hashableConformance() {
        let a = SMBBonjourDiscovery.discoveredServer(forServiceName: "Box")
        let b = SMBBonjourDiscovery.discoveredServer(forServiceName: "Box")
        let c = SMBBonjourDiscovery.discoveredServer(forServiceName: "Other")
        var set: Set<SMBDiscoveredServer> = [a, b, c]
        #expect(set.count == 2)
        set.insert(a)
        #expect(set.count == 2)
    }
}
