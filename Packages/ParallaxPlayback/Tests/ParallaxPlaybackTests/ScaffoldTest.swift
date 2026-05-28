import Testing
@testable import ParallaxPlayback

// This file is intentionally minimal — it asserts the module compiles.
// Real tests live in EngineSelectorTests.swift and per-type test files.
@Suite("Package scaffold")
struct ScaffoldTest {
    @Test("ParallaxPlayback module imports successfully")
    func moduleImports() {
        #expect(Bool(true))
    }
}
