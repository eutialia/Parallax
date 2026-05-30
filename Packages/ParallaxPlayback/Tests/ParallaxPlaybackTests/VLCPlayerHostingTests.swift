import Testing
@testable import ParallaxPlayback

@Suite("VLCPlayerHosting")
struct VLCPlayerHostingTests {

    @Test("VLCPlayerHosting protocol exists and is importable")
    func protocolExists() {
        // Compile-time check. The existential type itself is the assertion.
        let _: (any VLCPlayerHosting).Type = (any VLCPlayerHosting).self
        #expect(Bool(true))
    }

    @Test("VLCKitEngine conforms to VLCPlayerHosting")
    @MainActor func engineConforms() {
        let engine = VLCKitEngine()
        let hosting = engine as? any VLCPlayerHosting
        #expect(hosting != nil)
    }
}
