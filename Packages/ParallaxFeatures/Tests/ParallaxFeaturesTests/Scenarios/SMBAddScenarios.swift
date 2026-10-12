import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import Testing

@MainActor
@Suite("SMB add and remove", .timeLimit(.minutes(1)))
struct SMBAddScenarios {
    private static let shares = [
        SMBShare(name: "Media", comment: "Movies & TV"),
        SMBShare(name: "Photos", comment: ""),
        SMBShare(name: "Backups", comment: ""),
    ]

    @Test("adding a discovered NAS from login lists its shares, saves the two picked, and lands on home with them as libraries")
    func addingANASSavesThePickedShares() async throws {
        let world = try await AppWorld.launch()
        world.nas.acceptOnly(password: "hunter2")
        world.nas.setShareListOutcome(.shares(Self.shares))
        let discovery = world.app.services.smbDiscovery
        let add = world.app.makeSMBAddServer()

        discovery.start()
        world.advertiseSMB(["Attic"])
        try await world.until { discovery.discovered.map(\.host) == ["Attic.local"] }
        add.host = discovery.discovered[0].host
        add.username = "ana"
        add.password = "hunter2"
        add.connect()
        try await world.until { add.showShareSelector }

        #expect(add.discoveredShares.map(\.name) == ["Media", "Photos", "Backups"])
        add.toggleShare("Photos")
        add.toggleShare("Media")
        #expect(await add.save())
        #expect(world.app.router.destination == .home)
        #expect(await world.smbLibraries() == ["Attic.local/Media", "Attic.local/Photos"])
    }

    @Test("a wrong password on connect says the server refused and saves nothing")
    func wrongPasswordSavesNothing() async throws {
        let world = try await AppWorld.launch()
        world.nas.acceptOnly(password: "hunter2")
        world.nas.setShareListOutcome(.shares(Self.shares))
        let add = world.app.makeSMBAddServer()

        add.host = " nas.local "
        add.username = "ana"
        add.password = "hunter3"
        add.connect()
        try await world.until { !add.isConnecting }

        #expect(add.connectionError == "Couldn't connect to nas.local. Check the host and credentials.")
        #expect(!add.showShareSelector)
        #expect(await world.smbLibraries() == [])
        #expect(world.app.router.destination == .login)
    }

    @Test("a host that never answers ends the connect at the 30-second watchdog with a timeout error")
    func silentHostTimesOut() async throws {
        let world = try await AppWorld.launch()
        let add = world.app.makeSMBAddServer()
        await world.nas.connectGate.close()

        add.host = "nas.local"
        add.connect()
        await world.nas.connectGate.awaitArrivals()
        await world.clock.waitForSleepers()
        world.clock.advance(by: .seconds(29))
        #expect(add.isConnecting)
        world.clock.advance(by: .seconds(1))
        try await world.until { !add.isConnecting }

        #expect(add.connectionError == "Timed out after 30 s (stage: listing-shares).")
        #expect(!add.showShareSelector)
        await world.nas.connectGate.open()
    }

    @Test("removing the only NAS drops its libraries and its saved shares, and returns to login")
    func removingTheNASDropsItsLibraries() async throws {
        let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media", "Photos"])
        let world = try await AppWorld.launch(savedSMB: [(nas, "hunter2")])
        #expect(world.app.router.destination == .home)
        #expect(await world.smbLibraries() == ["nas.local/Media", "nas.local/Photos"])

        let settings = world.app.makeSMBServerSettings(id: ServerID(rawValue: "smb-nas.local"), data: nas)
        await settings.remove()

        #expect(await world.smbLibraries() == [])
        #expect(world.app.router.destination == .login)
    }
}
