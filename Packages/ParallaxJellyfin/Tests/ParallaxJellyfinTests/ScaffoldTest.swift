import Testing
@testable import ParallaxJellyfin

@Suite("Package scaffold")
struct ScaffoldTest {
    @Test("ParallaxJellyfin module imports successfully")
    func moduleImports() {
        #expect(Bool(true))
    }
}
