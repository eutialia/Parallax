import CoreGraphics
import Observation
import ParallaxSubtitles

/// What the subtitle overlay draws from: a canvas and a frame for a playhead time.
nonisolated public protocol SubtitleFrameSource: AnyObject, Sendable {
    func setCanvas(size: CGSize, scale: CGFloat, storageSize: CGSize?) async
    func frame(at seconds: Double) async -> SubtitleFrame?
}

extension SubtitleRenderer: SubtitleFrameSource {}

/// The player's side of the subtitle overlay: the loaded source, the engine clock and the clock
/// the driver ticks on.
public struct SubtitleFeed {
    /// The loaded source and its generation, or nil when the overlay has nothing to draw.
    /// Generation, not identity: a freed renderer's address can be reused by the next one.
    let source: () -> (source: any SubtitleFrameSource, generation: Int)?
    /// The engine's playhead in seconds, or nil while it can't be read (no engine, or VLC's
    /// clock during buffering and seeks).
    let engineSeconds: () -> Double?
    let clock: any Clock<Duration>

}

/// Polls the engine clock ~15×/s and keeps the frame the track says belongs on screen now.
/// Playback-state beats (0.5s) are far too coarse for sub-second cues, so it reads the engine
/// clock directly. Owned by one overlay mount; the overlay draws `shownFrame`.
@Observable
public final class SubtitleDriver {
    /// Where the overlay wants the canvas, in points.
    public struct Canvas: Equatable, Sendable {
        public let rect: CGRect
        public let storage: CGSize?

        public init(rect: CGRect, storage: CGSize?) {
            self.rect = rect
            self.storage = storage
        }
    }

    public static let tick: Duration = .milliseconds(66)

    private(set) var frame: SubtitleFrame?
    /// While the engine clock can't be read the last frame is hidden, not discarded: the
    /// renderer's change-tracking doesn't know the overlay blanked, so discarding would lose the
    /// cue until the next cue transition once the clock returns.
    private(set) var clockValid = true

    public init() {}

    public var shownFrame: SubtitleFrame? { clockValid ? frame : nil }

    /// Runs until cancelled. The canvas is pushed when the source's generation, the rect or the
    /// scale changes, and `onCanvasPushed` runs after each push. `frame(at:)` returns nil when
    /// nothing changed, so idle ticks are cheap.
    public func run(_ feed: SubtitleFeed, scale: CGFloat, canvas: () -> Canvas,
                    onCanvasPushed: () -> Void) async {
        var pushed: CanvasKey?
        while !Task.isCancelled {
            guard let (source, generation) = feed.source() else {
                // Unguarded, this write would notify the overlay on every tick of a session
                // with subtitles off: `SubtitleFrame` is not Equatable.
                if frame != nil { frame = nil }
                pushed = nil
                try? await feed.clock.sleep(for: Self.tick)
                continue
            }
            let wanted = canvas()
            let key = CanvasKey(generation: generation, rect: wanted.rect, scale: scale)
            if key != pushed, wanted.rect.size != .zero {
                await source.setCanvas(size: wanted.rect.size, scale: scale, storageSize: wanted.storage)
                pushed = key
                onCanvasPushed()
            }
            // AVKit always reports a valid time (0 at the start), so a genuine 0:00 cue shows.
            // Matching absolute cue times against the engine clock holds only while an
            // out-of-buffer transcode seek restarts ffmpeg frame-accurately under the item's
            // timeline mapping (see PlayerViewModel.seek(to:)).
            if let now = feed.engineSeconds() {
                clockValid = true
                if pushed != nil, let fresh = await source.frame(at: now) {
                    frame = fresh
                }
            } else {
                clockValid = false
            }
            try? await feed.clock.sleep(for: Self.tick)
        }
    }

    private struct CanvasKey: Equatable {
        let generation: Int
        let rect: CGRect
        let scale: CGFloat
    }
}
