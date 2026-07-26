import Testing
import ParallaxCore
import ParallaxPlayback

/// The matrix is a declaration, so here — and only here — the literal sets ARE the
/// spec. Every other suite in the package asserts against `PlaybackCapabilityMatrix.*`
/// rather than re-typing these lists.
@Suite("PlaybackCapabilityMatrix")
struct PlaybackCapabilityMatrixTests {

    // MARK: — AVKit exact whitelists (what EngineSelector routes on)

    @Test("avKitContainers is exactly mp4/mov/hls")
    func avKitContainers() {
        #expect(PlaybackCapabilityMatrix.avKitContainers == [.mp4, .mov, .hls])
    }

    @Test("avKitVideoCodecs is exactly h264/hevc")
    func avKitVideoCodecs() {
        #expect(PlaybackCapabilityMatrix.avKitVideoCodecs == [.h264, .hevc])
    }

    /// Also pins the wiring to ParallaxCore's shared `avPlayerSupported`, which
    /// MediaProbe's worst-case track pick reads from the other side.
    @Test("avKitAudioCodecs is exactly aac/ac3/eac3/mp3, shared with ParallaxCore")
    func avKitAudioCodecs() {
        #expect(PlaybackCapabilityMatrix.avKitAudioCodecs == [.aac, .ac3, .eac3, .mp3])
        #expect(PlaybackCapabilityMatrix.avKitAudioCodecs == AudioCodec.avPlayerSupported)
    }

    @Test("avKitSubtitleFormats is exactly vtt/srt")
    func avKitSubtitleFormats() {
        #expect(PlaybackCapabilityMatrix.avKitSubtitleFormats == [.vtt, .srt])
    }

    // MARK: — VLC is a superset on every axis

    /// Compared as raw-value sets so one table can cover four differently-typed axes.
    /// A VLC set that ever lost an AVKit-playable format would silently make the
    /// fallback engine *less* capable than the primary.
    @Test("every VLC axis is a superset of the matching AVKit axis", arguments: [
        ("containers", Set(PlaybackCapabilityMatrix.avKitContainers.map(\.rawValue)),
         Set(PlaybackCapabilityMatrix.vlcContainers.map(\.rawValue))),
        ("videoCodecs", Set(PlaybackCapabilityMatrix.avKitVideoCodecs.map(\.rawValue)),
         Set(PlaybackCapabilityMatrix.vlcVideoCodecs.map(\.rawValue))),
        ("audioCodecs", Set(PlaybackCapabilityMatrix.avKitAudioCodecs.map(\.rawValue)),
         Set(PlaybackCapabilityMatrix.vlcAudioCodecs.map(\.rawValue))),
        ("subtitleFormats", Set(PlaybackCapabilityMatrix.avKitSubtitleFormats.map(\.rawValue)),
         Set(PlaybackCapabilityMatrix.vlcSubtitleFormats.map(\.rawValue))),
    ])
    func vlcIsSupersetOfAVKit(axis: String, avKit: Set<String>, vlc: Set<String>) {
        #expect(avKit.isSubset(of: vlc), "\(axis): VLC dropped \(avKit.subtracting(vlc))")
    }

    // MARK: — VLC-only coverage (the reason the fallback engine exists)

    @Test("vlcContainers covers the long tail AVKit cannot open",
          arguments: [Container.mkv, .webm, .ts, .flac, .mp3, .avi])
    func vlcContainersInclude(container: Container) {
        #expect(PlaybackCapabilityMatrix.vlcContainers.contains(container))
    }

    @Test("vlcVideoCodecs covers the codecs VideoToolbox cannot feed AVPlayer",
          arguments: [VideoCodec.vp9, .av1, .vc1, .mpeg2video])
    func vlcVideoCodecsInclude(codec: VideoCodec) {
        #expect(PlaybackCapabilityMatrix.vlcVideoCodecs.contains(codec))
    }

    @Test("vlcAudioCodecs covers the lossless/object formats AVPlayer rejects",
          arguments: [AudioCodec.dts, .trueHD, .flac, .opus])
    func vlcAudioCodecsInclude(codec: AudioCodec) {
        #expect(PlaybackCapabilityMatrix.vlcAudioCodecs.contains(codec))
    }

    @Test("vlcSubtitleFormats covers libass and the image-based formats",
          arguments: [SubtitleFormat.ass, .pgs, .vobsub])
    func vlcSubtitleFormatsInclude(format: SubtitleFormat) {
        #expect(PlaybackCapabilityMatrix.vlcSubtitleFormats.contains(format))
    }

    // MARK: — Derived "software" tier stays derived

    /// These three guard against a future hand-edit turning a derived set into a typed
    /// literal — the failure mode that would quietly ship a VLC direct-play tier
    /// advertising h264/hevc and lose HDR/DV/Atmos on premium MKV content.

    @Test("softwareVideoCodecs == vlcVideoCodecs − avKitVideoCodecs")
    func softwareVideoCodecsDerivedCorrectly() {
        #expect(PlaybackCapabilityMatrix.softwareVideoCodecs
            == PlaybackCapabilityMatrix.vlcVideoCodecs
                .subtracting(PlaybackCapabilityMatrix.avKitVideoCodecs))
    }

    @Test("softwareAudioCodecs == vlcAudioCodecs − avKitAudioCodecs")
    func softwareAudioCodecsDerivedCorrectly() {
        #expect(PlaybackCapabilityMatrix.softwareAudioCodecs
            == PlaybackCapabilityMatrix.vlcAudioCodecs
                .subtracting(PlaybackCapabilityMatrix.avKitAudioCodecs))
    }

    @Test("softwareContainers == vlcContainers − avKitContainers")
    func softwareContainersDerivedCorrectly() {
        #expect(PlaybackCapabilityMatrix.softwareContainers
            == PlaybackCapabilityMatrix.vlcContainers
                .subtracting(PlaybackCapabilityMatrix.avKitContainers))
    }
}
