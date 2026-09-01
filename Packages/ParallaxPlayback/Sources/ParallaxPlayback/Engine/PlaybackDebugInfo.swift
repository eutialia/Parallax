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
    /// Every `AVPlayerItemAccessLogEvent`, oldest first, one entry per media request run:
    /// "path reqs=N bytes=N ibr=N start=Ns session=…". The error log says a request FAILED;
    /// this says which requests were ATTEMPTED and in what order — the only way to tell "the
    /// player asked for the resume segment and the server dropped it" apart from "the player
    /// asked for segment 0 and the server restarted the encode underneath it". `numberOfMediaRequests`
    /// counting 1 with `bytes=0` is the signature of a single request that died mid-flight.
    /// URIs are reduced the same way `errorLogTail`'s are, and every other field is a number
    /// AVFoundation authored — so unlike the error log this whole string is safe at `.public`.
    public var accessLogTail: [String]

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
        selectedAudible: String? = nil,
        legibleOptions: [String] = [],
        selectedLegible: String? = nil,
        subtitleDelayMs: Int? = nil,
        transportState: String? = nil,
        stallCount: Int? = nil,
        bytesTransferred: Int64? = nil,
        errorLogTail: [String] = [],
        accessLogTail: [String] = []
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
        self.selectedAudible = selectedAudible
        self.legibleOptions = legibleOptions
        self.selectedLegible = selectedLegible
        self.subtitleDelayMs = subtitleDelayMs
        self.transportState = transportState
        self.stallCount = stallCount
        self.bytesTransferred = bytesTransferred
        self.errorLogTail = errorLogTail
        self.accessLogTail = accessLogTail
    }

    public static let empty = PlaybackDebugInfo()

    /// One line naming what the engine was doing — the fields that answer "why did this never
    /// start / never recover" when a watchdog gives up: item status, transport, where the
    /// playhead sits versus what is actually buffered. Every field here is a number or a
    /// closed vocabulary the engine itself produced, so it logs `.public`. The HLS error log
    /// is deliberately NOT part of it — see `errorLogDetail`.
    public var logSummary: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        return """
            item=\(itemStatus ?? "—") transport=\(transportState ?? "—") \
            playhead=\(number(playheadSeconds)) buffered=\(number(bufferedSeconds)) \
            ranges=[\(loadedRanges.joined(separator: ", "))] \
            bitrate=\(number(observedBitrate))/\(number(indicatedBitrate)) \
            bytes=\(bytesTransferred.map(String.init) ?? "—") stalls=\(stallCount.map(String.init) ?? "—")
            """
    }

    /// The HLS error log tail — the field that usually holds the actual diagnosis (a yanked
    /// playlist, a 401, a segment that never arrived). Split out of `logSummary` because it is
    /// the one field the app does not author: each entry appends CoreMedia's own
    /// `errorComment`, free text that can echo the request it failed on. URIs are already
    /// reduced to a trailing path (`AVKitEngine.redactedTail`), but the comment is not, so a
    /// log site must emit THIS at `.private` and the summary above at `.public`.
    public var errorLogDetail: String {
        errorLogTail.isEmpty ? "none" : errorLogTail.joined(separator: " | ")
    }

    /// The access log, whole. Every field in it is either a number AVFoundation reported or a
    /// URI already reduced to a query-free trailing path, so — unlike `errorLogDetail` — this
    /// carries no free text and logs `.public`: the request sequence stays readable on a device
    /// with private logging off.
    public var accessLogDetail: String {
        accessLogTail.isEmpty ? "none" : accessLogTail.joined(separator: " | ")
    }
}
