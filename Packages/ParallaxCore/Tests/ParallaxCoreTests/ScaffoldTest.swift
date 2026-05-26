import Testing
@testable import ParallaxCore

@Suite("Package scaffold")
struct ScaffoldTest {
    @Test("ParallaxCore module imports successfully")
    func moduleImports() {
        #expect(Bool(true))
    }
}
