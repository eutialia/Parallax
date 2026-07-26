import Testing
@testable import ParallaxPlayback

@Suite("VLCPlayerHosting")
struct VLCPlayerHostingTests {

    /// The app target casts `any PlaybackEngine` to `any VLCPlayerHosting` at the
    /// `VLCVideoHost` boundary and sets `vlcPlayer.drawable`. A failed cast — or a
    /// hosting property handing back a *different* player than the engine drives —
    /// would render into a surface nothing decodes to.
    @Test("VLCKitEngine conforms to VLCPlayerHosting and vends the player it drives")
    @MainActor func engineConforms() {
        let engine = VLCKitEngine()
        let hosting: any VLCPlayerHosting = engine
        #expect(hosting.vlcPlayer === engine.vlcPlayer)
    }
}
