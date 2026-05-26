import Testing
@testable import ParallaxPlayback

@Suite("Package scaffold")
struct ScaffoldTest {
    @Test("ParallaxPlayback module imports successfully")
    func moduleImports() {
        #expect(Bool(true))
    }
}
