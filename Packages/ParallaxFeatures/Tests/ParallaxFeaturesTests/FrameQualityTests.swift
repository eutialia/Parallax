import Foundation
import Testing
@testable import ParallaxFeatures

@Suite("Frame quality")
struct FrameQualityTests {
    @Test("a grey mosaic is rejected; lit, dark, black and black-and-white frames are kept", arguments: [
        ("mosaic", TestFrames.mosaic, false),
        ("scene", TestFrames.scene, true),
        ("dark", TestFrames.dark, true),
        ("black", TestFrames.black, true),
        ("fog", TestFrames.fog, true),
    ])
    func usability(name: String, frame: Data, usable: Bool) {
        #expect(FrameQuality.isUsable(frame) == usable)
    }

    @Test("bytes that don't decode are not a usable frame")
    func undecodable() {
        #expect(FrameQuality.isUsable(Data("frame".utf8)) == false)
    }
}
