import Testing
import ParallaxCore
@testable import ParallaxPlayback

@Suite("PlaybackCapabilityMatrix")
struct PlaybackCapabilityMatrixTests {

    // MARK: — AVKit sets

    @Test("avKitContainers includes mp4, mov, hls and nothing else")
    func avKitContainers() {
        #expect(PlaybackCapabilityMatrix.avKitContainers == [.mp4, .mov, .hls])
    }

    @Test("avKitVideoCodecs includes h264 and hevc only")
    func avKitVideoCodecs() {
        #expect(PlaybackCapabilityMatrix.avKitVideoCodecs == [.h264, .hevc])
    }

    @Test("avKitAudioCodecs includes aac, ac3, eac3, mp3")
    func avKitAudioCodecs() {
        #expect(PlaybackCapabilityMatrix.avKitAudioCodecs == [.aac, .ac3, .eac3, .mp3])
    }

    @Test("avKitSubtitleFormats includes vtt and srt only")
    func avKitSubtitleFormats() {
        #expect(PlaybackCapabilityMatrix.avKitSubtitleFormats == [.vtt, .srt])
    }

    // MARK: — VLC sets

    @Test("vlcContainers is a superset of avKitContainers")
    func vlcContainersSupersetOfAVKit() {
        #expect(PlaybackCapabilityMatrix.avKitContainers.isSubset(of: PlaybackCapabilityMatrix.vlcContainers))
    }

    @Test("vlcContainers includes mkv, webm, ts, flac, mp3")
    func vlcContainersIncludes() {
        let vlc = PlaybackCapabilityMatrix.vlcContainers
        #expect(vlc.contains(.mkv))
        #expect(vlc.contains(.webm))
        #expect(vlc.contains(.ts))
        #expect(vlc.contains(.flac))
        #expect(vlc.contains(.mp3))
    }

    @Test("vlcVideoCodecs is a superset of avKitVideoCodecs")
    func vlcVideoCodecsSupersetOfAVKit() {
        #expect(PlaybackCapabilityMatrix.avKitVideoCodecs.isSubset(of: PlaybackCapabilityMatrix.vlcVideoCodecs))
    }

    @Test("vlcVideoCodecs includes vp9 and av1")
    func vlcVideoCodecsIncludes() {
        let vlc = PlaybackCapabilityMatrix.vlcVideoCodecs
        #expect(vlc.contains(.vp9))
        #expect(vlc.contains(.av1))
    }

    @Test("vlcAudioCodecs is a superset of avKitAudioCodecs")
    func vlcAudioCodecsSupersetOfAVKit() {
        #expect(PlaybackCapabilityMatrix.avKitAudioCodecs.isSubset(of: PlaybackCapabilityMatrix.vlcAudioCodecs))
    }

    @Test("vlcAudioCodecs includes dts, trueHD, flac, opus")
    func vlcAudioCodecsIncludes() {
        let vlc = PlaybackCapabilityMatrix.vlcAudioCodecs
        #expect(vlc.contains(.dts))
        #expect(vlc.contains(.trueHD))
        #expect(vlc.contains(.flac))
        #expect(vlc.contains(.opus))
    }

    @Test("vlcSubtitleFormats includes ass, pgs, vobsub")
    func vlcSubtitleFormatsIncludes() {
        let vlc = PlaybackCapabilityMatrix.vlcSubtitleFormats
        #expect(vlc.contains(.ass))
        #expect(vlc.contains(.pgs))
        #expect(vlc.contains(.vobsub))
    }

    // MARK: — Derived "software" sets (vlc minus avKit)

    @Test("softwareVideoCodecs excludes h264 and hevc")
    func softwareVideoCodecsExcludesAVKit() {
        let sw = PlaybackCapabilityMatrix.softwareVideoCodecs
        #expect(!sw.contains(.h264))
        #expect(!sw.contains(.hevc))
    }

    @Test("softwareVideoCodecs includes vp9 and av1")
    func softwareVideoCodecsIncludesVLCExtra() {
        let sw = PlaybackCapabilityMatrix.softwareVideoCodecs
        #expect(sw.contains(.vp9))
        #expect(sw.contains(.av1))
    }

    @Test("softwareAudioCodecs excludes aac, ac3, eac3, mp3")
    func softwareAudioCodecsExcludesAVKit() {
        let sw = PlaybackCapabilityMatrix.softwareAudioCodecs
        #expect(!sw.contains(.aac))
        #expect(!sw.contains(.ac3))
        #expect(!sw.contains(.eac3))
        #expect(!sw.contains(.mp3))
    }

    @Test("softwareAudioCodecs includes dts, trueHD, flac, opus")
    func softwareAudioCodecsIncludesVLCExtra() {
        let sw = PlaybackCapabilityMatrix.softwareAudioCodecs
        #expect(sw.contains(.dts))
        #expect(sw.contains(.trueHD))
        #expect(sw.contains(.flac))
        #expect(sw.contains(.opus))
    }

    @Test("softwareContainers excludes mp4, mov, hls")
    func softwareContainersExcludesAVKit() {
        let sw = PlaybackCapabilityMatrix.softwareContainers
        #expect(!sw.contains(.mp4))
        #expect(!sw.contains(.mov))
        #expect(!sw.contains(.hls))
    }

    @Test("softwareContainers includes mkv, webm, ts")
    func softwareContainersIncludesVLCExtra() {
        let sw = PlaybackCapabilityMatrix.softwareContainers
        #expect(sw.contains(.mkv))
        #expect(sw.contains(.webm))
        #expect(sw.contains(.ts))
    }

    // MARK: — Derived sets are mathematically correct

    @Test("softwareVideoCodecs == vlcVideoCodecs subtracting avKitVideoCodecs")
    func softwareVideoCodecsDerivedCorrectly() {
        let expected = PlaybackCapabilityMatrix.vlcVideoCodecs
            .subtracting(PlaybackCapabilityMatrix.avKitVideoCodecs)
        #expect(PlaybackCapabilityMatrix.softwareVideoCodecs == expected)
    }

    @Test("softwareAudioCodecs == vlcAudioCodecs subtracting avKitAudioCodecs")
    func softwareAudioCodecsDerivedCorrectly() {
        let expected = PlaybackCapabilityMatrix.vlcAudioCodecs
            .subtracting(PlaybackCapabilityMatrix.avKitAudioCodecs)
        #expect(PlaybackCapabilityMatrix.softwareAudioCodecs == expected)
    }

    @Test("softwareContainers == vlcContainers subtracting avKitContainers")
    func softwareContainersDerivedCorrectly() {
        let expected = PlaybackCapabilityMatrix.vlcContainers
            .subtracting(PlaybackCapabilityMatrix.avKitContainers)
        #expect(PlaybackCapabilityMatrix.softwareContainers == expected)
    }
}
