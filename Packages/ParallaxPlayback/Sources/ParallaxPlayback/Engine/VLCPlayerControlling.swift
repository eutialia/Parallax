import CoreGraphics
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif

/// The slice of `VLCMediaPlayer` that `VLCKitEngine` actually drives — the engine holds
/// `any VLCPlayerControlling` so its poll loop, latches, delay round-trip and state mapping
/// can be exercised against a spy instead of a live decode. `VLCMediaPlayer` conforms
/// verbatim (every member below matches the 3.7.3 header), so the production path is
/// unchanged.
///
/// Deliberately narrow: nothing goes in here that the engine does not call. The drawable
/// host still needs the concrete class — see `VLCPlayerHosting.vlcPlayer`.
public protocol VLCPlayerControlling: AnyObject {

    // MARK: Clock and transport

    /// 3.x's clock. Reads are a cache libvlc's time-changed event refreshes, so a write is
    /// NOT immediately visible through the getter — the whole reason `heldPositionMs` exists.
    var time: VLCTime { get set }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    var isSeekable: Bool { get }
    var state: VLCMediaPlayerState { get }
    func play()
    func pause()
    /// Synchronous and blocking on 3.x: it winds the input down on the calling thread.
    func stop()

    // MARK: Media and output

    var media: VLCMedia? { get set }
    var audio: VLCAudio? { get }
    var videoSize: CGSize { get }
    var drawable: Any? { get set }
    var delegate: (any VLCMediaPlayerDelegate)? { get set }
    func saveVideoSnapshot(at path: String, withWidth width: Int32, andHeight height: Int32)

    // MARK: Tracks

    /// Written with the libvlc track id; -1 disables. The parallel index/name arrays below
    /// are the whole 3.x track API.
    var currentAudioTrackIndex: Int32 { get set }
    var currentVideoSubTitleIndex: Int32 { get set }
    /// Microseconds, positive = later.
    var currentVideoSubTitleDelay: Int { get set }
    var audioTrackIndexes: [Any] { get }
    var audioTrackNames: [Any] { get }
    var videoSubTitlesIndexes: [Any] { get }
    var videoSubTitlesNames: [Any] { get }
}

extension VLCMediaPlayer: VLCPlayerControlling {}
