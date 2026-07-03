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

    @Test(".systemDefault leaves both AVPlayerItem/AVPlayer properties untouched")
    func systemDefaultAppliesNothing() {
        let item = makeItem()
        let player = AVPlayer()
        let bufferBefore = item.preferredForwardBufferDuration
        let waitsBefore = player.automaticallyWaitsToMinimizeStalling

        AVKitEngine.applyTuning(.systemDefault, to: item, player: player)

        #expect(item.preferredForwardBufferDuration == bufferBefore)
        #expect(player.automaticallyWaitsToMinimizeStalling == waitsBefore)
    }

    @Test("An explicit tuning applies both properties")
    func explicitTuningAppliesBoth() {
        let item = makeItem()
        let player = AVPlayer()
        let tuning = StartupTuning(preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: false)

        AVKitEngine.applyTuning(tuning, to: item, player: player)

        #expect(item.preferredForwardBufferDuration == 3)
        #expect(player.automaticallyWaitsToMinimizeStalling == false)
    }

    @Test("A partial tuning (one nil field) leaves only the nil field untouched")
    func partialTuningLeavesNilFieldUntouched() {
        let item = makeItem()
        let player = AVPlayer()
        let waitsBefore = player.automaticallyWaitsToMinimizeStalling
        let tuning = StartupTuning(preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: nil)

        AVKitEngine.applyTuning(tuning, to: item, player: player)

        #expect(item.preferredForwardBufferDuration == 3)
        #expect(player.automaticallyWaitsToMinimizeStalling == waitsBefore)
    }

    @Test("AVKitEngine.init defaults to .systemDefault and existing zero-arg call sites still compile")
    func engineDefaultsToSystemTuning() {
        let engine = AVKitEngine()
        #expect(engine.id == .avKit)
    }
}
