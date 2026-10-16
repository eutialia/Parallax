import Testing
import ParallaxCore
import ParallaxPlayback

/// The matrix is a declaration, so here — and only here — the literal sets ARE the
/// spec.
@Suite("PlaybackCapabilityMatrix")
struct PlaybackCapabilityMatrixTests {

    @Test("avKitSubtitleFormats is exactly vtt/srt")
    func avKitSubtitleFormats() {
        #expect(PlaybackCapabilityMatrix.avKitSubtitleFormats == [.vtt, .srt])
    }

    /// A VLC set that ever lost an AVKit-renderable format would silently make the
    /// fallback engine *less* capable than the primary.
    @Test("vlcSubtitleFormats is a superset of avKitSubtitleFormats")
    func vlcSubtitlesAreSupersetOfAVKit() {
        let missing = PlaybackCapabilityMatrix.avKitSubtitleFormats
            .subtracting(PlaybackCapabilityMatrix.vlcSubtitleFormats)
        #expect(missing.isEmpty, "VLC dropped \(missing)")
    }

    // MARK: — VLC-only coverage (the reason the fallback engine exists)

    @Test("vlcContainers covers the long tail AVKit cannot open",
          arguments: [Container.mkv, .webm, .ts, .flac, .mp3, .avi])
    func vlcContainersInclude(container: Container) {
        #expect(PlaybackCapabilityMatrix.vlcContainers.contains(container))
    }

    @Test("vlcVideoCodecs covers VP9, AV1, VC-1 and MPEG-2",
          arguments: [VideoCodec.vp9, .av1, .vc1, .mpeg2video])
    func vlcVideoCodecsInclude(codec: VideoCodec) {
        #expect(PlaybackCapabilityMatrix.vlcVideoCodecs.contains(codec))
    }

    @Test("vlcAudioCodecs covers DTS, FLAC and Opus",
          arguments: [AudioCodec.dts, .flac, .opus])
    func vlcAudioCodecsInclude(codec: AudioCodec) {
        #expect(PlaybackCapabilityMatrix.vlcAudioCodecs.contains(codec))
    }

    /// No shippable libvlc build carries a TrueHD/MLP decoder (VideoLAN's build-config
    /// allowlist omits it — proven on MobileVLCKit 3.7.3). Advertising it would ask a
    /// server to direct-play a stream that decodes to silence.
    @Test("the VLC tier does not advertise TrueHD — the libvlc we ship cannot decode it")
    func trueHDIsNotAdvertisedByVLC() {
        #expect(!PlaybackCapabilityMatrix.vlcAudioCodecs.contains(.trueHD))
    }

    @Test("vlcSubtitleFormats covers libass and the image-based formats",
          arguments: [SubtitleFormat.ass, .pgs, .vobsub])
    func vlcSubtitleFormatsInclude(format: SubtitleFormat) {
        #expect(PlaybackCapabilityMatrix.vlcSubtitleFormats.contains(format))
    }
}
