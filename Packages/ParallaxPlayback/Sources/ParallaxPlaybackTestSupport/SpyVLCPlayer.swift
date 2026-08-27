import CoreGraphics
import Foundation
import ParallaxPlayback
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif

/// A recording stand-in for `VLCMediaPlayer`, injected through
/// `VLCKitEngine.init(control:)` so the poll loop, the seek/resume holds, the track latches
/// and the delay round-trip can be exercised without a decode.
///
/// **Models 3.x's clock honestly:** writing `time` records a seek but does NOT change what
/// the getter returns. That is exactly what libvlc does — `player.time` is a cache its
/// time-changed event refreshes, so it keeps reporting the pre-seek position for as long as
/// the input takes to demux at the new offset. Tests move the clock by assigning
/// `stubbedTime`, which is the analogue of that event landing.
///
/// `@unchecked Sendable`: the engine drives every member from the `@MainActor` except
/// `stop()`, which it deliberately runs detached — that one path is lock-guarded.
public final class SpyVLCPlayer: VLCPlayerControlling, @unchecked Sendable {

    // MARK: Recorded writes

    /// Every `time` write, in milliseconds (`VLCTime.value == nil` → nil).
    public private(set) var seekWritesMs: [Int32?] = []
    public private(set) var audioTrackWrites: [Int32] = []
    public private(set) var subtitleTrackWrites: [Int32] = []
    /// Every `currentVideoSubTitleDelay` write, in microseconds.
    public private(set) var subtitleDelayWrites: [Int] = []
    public private(set) var rateWrites: [Float] = []
    public private(set) var playCalls = 0
    public private(set) var pauseCalls = 0
    public private(set) var snapshotRequests: [String] = []

    private let lock = NSLock()
    private var _stopCalls = 0
    private var _stopCalledOnMainThread: Bool?
    private var _stopsHeld = false
    /// Parks a gated `stop()` until a test lets it through, so the engine's wind-down window
    /// is a state a test can stand inside and probe rather than a race to win.
    private let stopGate = DispatchSemaphore(value: 0)

    public var stopCalls: Int { lock.withLock { _stopCalls } }
    /// Whether the FIRST `stop()` ran on the main thread. Nil until one lands. 3.x's `stop()`
    /// blocks until the input is wound down, so a `true` here is a frozen dismissal on SMB.
    public var stopCalledOnMainThread: Bool? { lock.withLock { _stopCalledOnMainThread } }

    // MARK: Stubbed reads

    /// What the clock reports, independent of what has been written to `time`.
    public var stubbedTime: VLCTime = .null()
    public var stubbedState: VLCMediaPlayerState = .stopped
    public var stubbedIsPlaying = false
    public var stubbedIsSeekable = true
    public var stubbedVideoSize: CGSize = .zero
    public var stubbedAudioTrackIndexes: [Any] = []
    public var stubbedAudioTrackNames: [Any] = []
    public var stubbedSubtitleTrackIndexes: [Any] = []
    public var stubbedSubtitleTrackNames: [Any] = []

    public init() {}

    /// Move the clock the way libvlc's time-changed event does.
    public func advanceClock(toMs ms: Int32) {
        stubbedTime = VLCTime(int: ms)
    }

    // MARK: - VLCPlayerControlling

    public var time: VLCTime {
        get { stubbedTime }
        set { seekWritesMs.append(newValue.value.map { Int32(clamping: $0.int64Value) }) }
    }

    public var rate: Float = 1 {
        didSet { rateWrites.append(rate) }
    }

    public var isPlaying: Bool { stubbedIsPlaying }
    public var isSeekable: Bool { stubbedIsSeekable }
    public var state: VLCMediaPlayerState { stubbedState }

    public func play() {
        playCalls += 1
        stubbedIsPlaying = true
    }

    public func pause() {
        pauseCalls += 1
        stubbedIsPlaying = false
    }

    /// Park every subsequent `stop()` until `releaseHeldStop()`/`stopHolding()`.
    public func holdStops() { lock.withLock { _stopsHeld = true } }

    /// Lets exactly one parked `stop()` finish.
    public func releaseHeldStop() { stopGate.signal() }

    /// Stops parking, and releases whatever is already parked.
    public func stopHolding() {
        lock.withLock { _stopsHeld = false }
        stopGate.signal()
    }

    public func stop() {
        if lock.withLock({ _stopsHeld }) { stopGate.wait() }
        lock.withLock {
            if _stopCalledOnMainThread == nil { _stopCalledOnMainThread = Thread.isMainThread }
            _stopCalls += 1
        }
    }

    public var media: VLCMedia?
    /// Nil, like a player whose aout has not been built. The engine's mute writes are
    /// optional-chained, so they simply do not land — no spy assertion depends on them.
    public var audio: VLCAudio? { nil }
    public var videoSize: CGSize { stubbedVideoSize }
    public var drawable: Any?
    public weak var delegate: (any VLCMediaPlayerDelegate)?

    public func saveVideoSnapshot(at path: String, withWidth width: Int32, andHeight height: Int32) {
        snapshotRequests.append(path)
    }

    public var currentAudioTrackIndex: Int32 = -1 {
        didSet { audioTrackWrites.append(currentAudioTrackIndex) }
    }

    public var currentVideoSubTitleIndex: Int32 = -1 {
        didSet { subtitleTrackWrites.append(currentVideoSubTitleIndex) }
    }

    public var currentVideoSubTitleDelay: Int = 0 {
        didSet { subtitleDelayWrites.append(currentVideoSubTitleDelay) }
    }

    public var audioTrackIndexes: [Any] { stubbedAudioTrackIndexes }
    public var audioTrackNames: [Any] { stubbedAudioTrackNames }
    public var videoSubTitlesIndexes: [Any] { stubbedSubtitleTrackIndexes }
    public var videoSubTitlesNames: [Any] { stubbedSubtitleTrackNames }
}
