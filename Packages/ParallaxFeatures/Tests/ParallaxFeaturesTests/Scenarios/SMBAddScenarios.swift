import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import Testing
import ParallaxTestScaling

@MainActor
@Suite("SMB add and remove", .scaledTimeLimit())
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

    @Test("a Bonjour browse that failed while the app was away starts again on return, and a NAS that came up meanwhile is listed")
    func returningToTheFormRestartsAFailedBrowse() async throws {
        let world = try await AppWorld.launch()
        let add = world.app.makeSMBAddServer()
        world.advertiseSMB(["Attic"])
        let discovery = Task { await add.discoverServers() }
        try await world.until { add.discoveredServers.map(\.host) == ["Attic.local"] }

        world.background()
        world.smbBrowseFails()
        // Not rendered: the rows keep the last snapshot. Waits for the browse to wind down, so the
        // return below finds it ended rather than racing its exit.
        try await world.until { !world.app.services.smbDiscovery.isDiscovering }
        world.advertiseSMB(["Attic", "Basement"])
        world.foreground()

        try await world.until { add.discoveredServers.map(\.host) == ["Attic.local", "Basement.local"] }
        discovery.cancel()
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
        try await world.clock.waitForSleep(dueIn: .seconds(30))
        #expect(world.clock.pendingSleeps.first == .seconds(30), "something can end the connect before the watchdog")
        #expect(add.isConnecting)
        world.clock.advance(by: .seconds(30))
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

        let settings = world.app.makeSMBServerSettings(id: makeSMBRef(nas).id, data: nas)
        await settings.remove()

        #expect(await world.smbLibraries() == [])
        #expect(world.app.router.destination == .login)
    }
}
