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
}
