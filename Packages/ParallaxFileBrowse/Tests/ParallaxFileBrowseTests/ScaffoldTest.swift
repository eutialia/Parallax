import Testing
@testable import ParallaxFileBrowse

@Suite("Package scaffold")
struct ScaffoldTest {
    @Test("ParallaxFileBrowse module imports successfully")
    func moduleImports() {
        #expect(Bool(true))
    }
}
