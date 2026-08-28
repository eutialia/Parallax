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
/// **Models 3.x's clock honestly:** by default, writing `time` records a seek but does NOT
/// change what the getter returns. That is exactly what libvlc does — `player.time` is a cache
/// its time-changed event refreshes, so it keeps reporting the pre-seek position for as long as
/// the input takes to demux at the new offset. Tests move the clock by assigning
/// `stubbedTime`, which is the analogue of that event landing.
/// `timeWritesMoveTheClock` flips that, for the one thing the default cannot express — see
/// its own note.
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
    /// Makes a `time` write land in the getter, the way libvlc's cached clock does on a build
    /// (or at a moment) where `set_time` reaches it before the input republishes.
    ///
    /// Off by default because the opposite is the shape 3.x usually shows, and the whole file
    /// turns on it. It exists so a test can pin the one thing the default silently hides:
    /// WHERE a read of `player.time` sits relative to a write. Code that samples the pre-seek
    /// clock AFTER writing the target reads correctly only while this is off — it is not a
    /// property of the code, it is libvlc's timing, and this is how a test says so.
    public var timeWritesMoveTheClock = false
    /// What `demuxReadBytes` reports — the fetch-liveness signal the seek hold and the stall
    /// detector both gate on. Flat across polls = starving; climbing = the fetch is fine and
    /// only the clock is behind.
    public var stubbedDemuxReadBytes = 0
    /// Added to `stubbedDemuxReadBytes` once per progress-poll tick, so "the fetch trickles one
    /// byte per poll" is exact instead of a race: the engine samples the counter on its own
    /// 500 ms cadence, and a test driving it from outside would be guessing at that. 0 (the
    /// default) leaves the counter flat — a starving fetch.
    ///
    /// Hung off the `state` read rather than off `demuxReadBytes` (which is a pure getter, as
    /// a counter read should be): the poll asks for the player state exactly ONCE per tick,
    /// ahead of every gate, so it is the only per-poll signal this seam exposes. Advancing per
    /// READ made "one byte per poll" a lie the moment the engine read the counter twice in a
    /// tick — which it did, and the trickle then double-counted.
    public var demuxBytesPerPoll = 0
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
        set {
            seekWritesMs.append(newValue.value.map { Int32(clamping: $0.int64Value) })
            if timeWritesMoveTheClock { stubbedTime = newValue }
        }
    }

    public var demuxReadBytes: Int { stubbedDemuxReadBytes }

    public var rate: Float = 1 {
        didSet { rateWrites.append(rate) }
    }

    public var isPlaying: Bool { stubbedIsPlaying }
    public var isSeekable: Bool { stubbedIsSeekable }
    /// One read per progress-poll tick — see `demuxBytesPerPoll`, whose trickle rides it.
    public var state: VLCMediaPlayerState {
        stubbedDemuxReadBytes += demuxBytesPerPoll
        return stubbedState
    }

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

    public func saveVideoSnapshot(at path: String, withWidth width: Int32, andHeight height: Int32) {}

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
