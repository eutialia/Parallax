import Testing
import Foundation
import ParallaxPlayback

// These tests are intentionally thin — they exist to prove that the protocol
// declarations are well-formed and that the type system enforces the
// Sendable + actor-isolation constraints we rely on downstream.

@Suite("Protocol declarations compile")
struct ProtocolCompilationTests {

    @Test("CapabilityProbe can be used as an existential")
    func capabilityProbeExistential() async {
        // If this compiles, the protocol is well-formed: @MainActor hdrSupport()
        // + non-isolated audioOutput() + Sendable conformance are all consistent.
        let _: (any CapabilityProbe)? = nil
        #expect(Bool(true))   // trivially passes — compilation is the gate
    }

    @Test("AudioSessionControlling can be used as an existential")
    func audioSessionControllingExistential() {
        let _: (any AudioSessionControlling)? = nil
        #expect(Bool(true))
    }
}
