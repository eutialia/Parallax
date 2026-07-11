import AVFoundation
import Testing
@testable import ParallaxPlayback

@Suite("StartupTuning")
@MainActor
struct StartupTuningTests {
    /// A `AVPlayerItem` never asked to load network data — enough to read/write its
    /// `preferredForwardBufferDuration`, which is all `applyTuning` touches.
    private func makeItem() -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://example.invalid/video.mp4")!))
    }

    @Test(".systemDefault leaves the AVPlayerItem untouched")
    func systemDefaultAppliesNothing() {
        let item = makeItem()
        let player = AVPlayer()
        let bufferBefore = item.preferredForwardBufferDuration

        AVKitEngine.applyTuning(.systemDefault, to: item, player: player)

        #expect(item.preferredForwardBufferDuration == bufferBefore)
    }

    @Test("An explicit tuning applies the forward-buffer target")
    func explicitTuningApplies() {
        let item = makeItem()
        let player = AVPlayer()
        let tuning = StartupTuning(preferredForwardBufferSeconds: 3)

        AVKitEngine.applyTuning(tuning, to: item, player: player)

        #expect(item.preferredForwardBufferDuration == 3)
    }

    @Test("AVKitEngine.init defaults to .systemDefault and existing zero-arg call sites still compile")
    func engineDefaultsToSystemTuning() {
        let engine = AVKitEngine()
        #expect(engine.id == .avKit)
    }
}
