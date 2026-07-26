import AVFoundation
import Testing
@testable import ParallaxPlayback

@Suite("StartupTuning")
@MainActor
struct StartupTuningTests {
    /// An `AVPlayerItem` never asked to load network data — enough to read/write its
    /// `preferredForwardBufferDuration`, which is all `applyTuning` touches.
    private func makeItem() -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://example.invalid/video.mp4")!))
    }

    /// `nil` means "leave the property alone", NOT "write the documented default" — the
    /// distinction the type doc calls out, because touching a property at all pins
    /// behavior against a future OS default change.
    @Test(".systemDefault carries no knobs and leaves the item untouched")
    func systemDefaultAppliesNothing() {
        #expect(StartupTuning.systemDefault.preferredForwardBufferSeconds == nil)

        let item = makeItem()
        let before = item.preferredForwardBufferDuration
        AVKitEngine.applyTuning(.systemDefault, to: item, player: AVPlayer())
        #expect(item.preferredForwardBufferDuration == before)
    }

    /// 0 is a *meaningful* value ("let AVFoundation choose per-item"), distinct from nil,
    /// so it must be written through rather than treated as absent.
    @Test("an explicit forward-buffer target is written onto the item",
          arguments: [0.0, 1.0, 3.0, 12.5] as [Double])
    func explicitTuningApplies(seconds: Double) {
        let item = makeItem()
        AVKitEngine.applyTuning(
            StartupTuning(preferredForwardBufferSeconds: seconds),
            to: item,
            player: AVPlayer()
        )
        #expect(item.preferredForwardBufferDuration == seconds)
    }

    /// The tuning is item-scoped: the shipping profile must never mutate the shared
    /// `AVPlayer` (an `automaticallyWaitsToMinimizeStalling` knob lived here once and
    /// was deleted after it wedged the first `.playing` beat on device).
    @Test("applyTuning leaves the AVPlayer's stall-waiting policy alone")
    func doesNotTouchThePlayer() {
        let player = AVPlayer()
        let before = player.automaticallyWaitsToMinimizeStalling
        AVKitEngine.applyTuning(
            StartupTuning(preferredForwardBufferSeconds: 4),
            to: makeItem(),
            player: player
        )
        #expect(player.automaticallyWaitsToMinimizeStalling == before)
    }
}
