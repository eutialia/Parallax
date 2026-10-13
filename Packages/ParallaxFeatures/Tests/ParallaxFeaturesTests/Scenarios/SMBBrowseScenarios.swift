import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback
import Testing

@MainActor
@Suite("SMB browse", .timeLimit(.minutes(1)))
struct SMBBrowseScenarios {
    private static let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
    private static let ref = makeSMBRef(nas)

    private static func file(_ name: String, modified: TimeInterval = 0) -> SMBDirectoryEntry {
        SMBDirectoryEntry(name: name, isDirectory: false, size: 1, modifiedAt: Date(timeIntervalSince1970: modified))
    }

    private static func folder(_ name: String) -> SMBDirectoryEntry {
        SMBDirectoryEntry(name: name, isDirectory: true, size: 0, modifiedAt: nil)
    }

    @Test("browsing a share lists folders above films in the chosen order, and opening a folder lists what's inside")
    func browsingListsFoldersAndFilesInOrder() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.setFolder([
            Self.folder("Shows"), Self.file("Heat.mkv", modified: 300), Self.folder("Movies"),
            Self.file("Alien.mp4", modified: 100), Self.file("notes.txt"), Self.file("Brazil.avi", modified: 200),
        ], share: "Media")
        world.nas.setFolder([Self.file("Ran.mkv"), Self.file("Ikiru.mkv")], share: "Media", path: "Movies")

        let root = await world.openSMBFolder(Self.ref, share: "Media")
        try await world.until { !root.isLoading }
        #expect(root.folders.map(\.name) == ["Movies", "Shows"])
        #expect(root.media.map(\.displayTitle) == ["Alien", "Brazil", "Heat"])

        root.sortField = .dateModified
        try await world.until { root.media.map(\.displayTitle) == ["Heat", "Brazil", "Alien"] }
        #expect(root.folders.map(\.name) == ["Movies", "Shows"])

        let movies = await world.openSMBFolder(Self.ref, share: "Media", path: "Movies")
        try await world.until { !movies.isLoading }
        #expect(movies.folders.isEmpty)
        #expect(movies.media.map(\.displayTitle) == ["Ikiru", "Ran"])
    }

    @Test("a server whose saved password is gone shows the terminal credential state, and entering it again brings browsing back")
    func lostPasswordRecoversThroughPasswordEntry() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.acceptOnly(password: "hunter2")
        world.nas.setFolder([Self.folder("Movies")], share: "Media")
        world.loseSMBPassword(of: Self.ref)

        let root = await world.openSMBFolder(Self.ref, share: "Media")
        #expect(root.setup == .failed(
            message: "The saved password couldn't be read. Enter it again in this server's settings to reconnect.",
            isCredentialLoss: true
        ))
        #expect(!root.isStalled)

        var recovered = false
        let recovery = world.app.makeSMBPasswordRecovery(id: Self.ref.id, data: Self.nas) { recovered = true }
        recovery.password = "hunter3"
        recovery.submit()
        try await world.until { !recovery.isVerifying }
        #expect(recovery.errorMessage == "nas.local rejected that password. Check it and try again.")
        #expect(!recovered)

        recovery.password = "hunter2"
        recovery.submit()
        try await world.until { !recovery.isVerifying }
        #expect(recovered)
        await root.reopenAfterPasswordRecovery()
        try await world.until { root.folders.map(\.name) == ["Movies"] }
        #expect(root.setup == .open)
    }

    @Test("a folder whose first appearance was cancelled before it opened lists on the next appearance")
    func cancelledFirstAppearanceOpensOnTheNext() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.setFolder([Self.folder("Movies")], share: "Media")
        let level = world.app.makeSMBBrowse(SMBBrowsePath(ref: Self.ref, share: "Media", path: ""))

        let firstAppearance = Task { await level.appear() }
        firstAppearance.cancel()
        await firstAppearance.value
        #expect(level.setup == .opening)
        #expect(level.folders.isEmpty)

        await level.appear()
        try await world.until { level.folders.map(\.name) == ["Movies"] }
        #expect(level.setup == .open)
    }

    @Test("tapping a film asks the player to play it, resolved to a bridged URL that carries no credentials")
    func tappingAFilmPlaysTheResolvedItem() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.setFolder([Self.file("Heat.mkv"), Self.file("Heat.en.srt")], share: "Media", path: "Movies")
        world.nas.setContents(Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60)))
        let movies = await world.openSMBFolder(Self.ref, share: "Media", path: "Movies")
        try await world.until { !movies.isLoading }

        movies.play(try #require(movies.media.first))

        guard case .smb(let item, let ref) = world.app.playback.request?.target else {
            Issue.record("the presenter holds no SMB play request: \(String(describing: world.app.playback.request?.target))")
            return
        }
        #expect(item.displayTitle == "Heat")
        #expect(ref == Self.ref)
        let resolved = try await world.app.services.smbPlaybackResolver.resolve(item, ref: ref)
        #expect(resolved.url.scheme == "http")
        #expect(resolved.url.lastPathComponent == "Heat.mkv")
        #expect(!resolved.url.absoluteString.contains("hunter2"))
        #expect(resolved.vlcOptions == [])
        #expect(resolved.hints.scheme == "smb")
        #expect(resolved.hints.container == .mkv)
        #expect(resolved.subtitleURLs.values.map(\.absoluteString) == ["smb://nas.local/Media/Movies/Heat.en.srt"])
        await resolved.cleanup?()
    }
}
