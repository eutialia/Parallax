import Foundation

/// A point-in-time snapshot of what the engine is *actually* decoding and
/// rendering, for the in-player debug HUD. Distinct from the server's
/// `ResolvedPlayback` metadata: on a transcode the source may be 4K HEVC while
/// the engine decodes a 1080p H.264 HLS variant — this reports the latter.
///
/// Every field is optional / empty where the engine can't report it (VLC has no
/// HLS access log; AVKit has no subtitle-delay control), so the HUD shows "—"
/// rather than a wrong value.
public struct PlaybackDebugInfo: Sendable, Equatable {
    /// Actual decoded frame size.
    public var presentationWidth: Int?
    public var presentationHeight: Int?
    /// Frames per second currently being rendered.
    public var renderedFrameRate: Double?
    /// Bits/sec the selected HLS variant advertises (AVKit access log).
    public var indicatedBitrate: Double?
    /// Bits/sec actually pulled from the network (AVKit access log).
    public var observedBitrate: Double?
    /// Cumulative dropped video frames (AVKit access log).
    public var droppedVideoFrames: Int?
    /// Seconds of media buffered ahead of the playhead — CONTIGUOUS with it.
    /// Nil when nothing under the playhead is buffered, even if other ranges
    /// hold data (see `loadedRanges` for those).
    public var bufferedSeconds: Double?
    /// The playhead, in media seconds. Pairs with `loadedRanges` to expose a
    /// gap-at-playhead wedge: data buffered far from where playback must start.
    public var playheadSeconds: Double?
    /// Every buffered range as "start–end" seconds (AVKit `loadedTimeRanges`).
    /// A range parked away from the playhead is the signature of a resume/seek
    /// the server and player disagree about.
    public var loadedRanges: [String]
    /// AVPlayerItem.status: "unknown" / "ready" / "failed" — whether the item
    /// ever became playable at all, distinct from the transport's state.
    public var itemStatus: String?
    /// The engine's own audio option list + the one it's actively rendering.
    public var audibleOptions: [String]
    public var selectedAudible: String?
    /// The engine's own subtitle option list + the one actively rendering.
    /// Ground truth for "selected but doesn't render" — if a user picked a sub
    /// but `selectedLegible` is nil, the selection didn't take.
    public var legibleOptions: [String]
    /// nil = no subtitle is active right now.
    public var selectedLegible: String?
    /// Current subtitle timing offset in milliseconds (VLC). nil where the engine
    /// has no such control (AVKit). Positive = subtitles delayed vs audio.
    public var subtitleDelayMs: Int?
    /// The transport's raw truth, e.g. "playing", "paused", "waiting (minimize
    /// stalls)" — the discriminator for a silent never-starting stall (AVKit
    /// `timeControlStatus` + `reasonForWaitingToPlay`).
    public var transportState: String?
    /// Cumulative playback stalls (AVKit access log).
    public var stallCount: Int?
    /// Total bytes pulled for the current item (AVKit access log) — distinguishes
    /// "data flowing but never enough" from "nothing arriving at all".
    public var bytesTransferred: Int64?
    /// Last few HLS error-log events, "domain code @path: comment" — segment fetch
    /// and parse failures RETRY SILENTLY without ever failing the item, so a stream
    /// that "never plays, no error" usually confesses here. URIs are reduced to a
    /// redacted trailing path (query stripped — that's where the api_key lives),
    /// just enough to tell playlist vs init vs media segment apart.
    public var errorLogTail: [String]

    public init(
        presentationWidth: Int? = nil,
        presentationHeight: Int? = nil,
        renderedFrameRate: Double? = nil,
        indicatedBitrate: Double? = nil,
        observedBitrate: Double? = nil,
        droppedVideoFrames: Int? = nil,
        bufferedSeconds: Double? = nil,
        playheadSeconds: Double? = nil,
        loadedRanges: [String] = [],
        itemStatus: String? = nil,
        audibleOptions: [String] = [],
        selectedAudible: String? = nil,
        legibleOptions: [String] = [],
        selectedLegible: String? = nil,
        subtitleDelayMs: Int? = nil,
        transportState: String? = nil,
        stallCount: Int? = nil,
        bytesTransferred: Int64? = nil,
        errorLogTail: [String] = []
    ) {
        self.presentationWidth = presentationWidth
        self.presentationHeight = presentationHeight
        self.renderedFrameRate = renderedFrameRate
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.droppedVideoFrames = droppedVideoFrames
        self.bufferedSeconds = bufferedSeconds
        self.playheadSeconds = playheadSeconds
        self.loadedRanges = loadedRanges
        self.itemStatus = itemStatus
        self.audibleOptions = audibleOptions
        self.selectedAudible = selectedAudible
        self.legibleOptions = legibleOptions
        self.selectedLegible = selectedLegible
        self.subtitleDelayMs = subtitleDelayMs
        self.transportState = transportState
        self.stallCount = stallCount
        self.bytesTransferred = bytesTransferred
        self.errorLogTail = errorLogTail
    }

    public static let empty = PlaybackDebugInfo()

    /// Whether this engine offers live subtitle-delay correction (VLC yes, AVKit no).
    public var supportsSubtitleDelay: Bool { subtitleDelayMs != nil }
}
