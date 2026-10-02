import Foundation
import Testing
@testable import ParallaxCore

@Suite("MediaInfo enums")
struct MediaInfoTests {
    /// Container is a wire vocabulary: DeviceProfileTranslator joins these raw values into the
    /// Jellyfin container lists, so a case or spelling change is a compatibility event.
    @Test("Container raw values are exactly the wire spellings the profile sends")
    func containerRawValues() {
        #expect(Set(Container.allCases.map(\.rawValue)) == ["mp4", "mov", "mkv", "webm", "ts", "hls", "flac", "mp3", "avi"])
    }

    /// One table for every wire spelling the mapper must accept: server strings arrive
    /// punctuated ("H.264"), cased ("HEVC"), abbreviated ("mpeg2") and aliased ("hvc1").
    @Test("VideoCodec parses every accepted wire identifier", arguments: [
        ("h264", VideoCodec.h264), ("avc", .h264), ("avc1", .h264), ("H.264", .h264), ("H264", .h264),
        ("hevc", .hevc), ("h265", .hevc), ("hvc1", .hevc), ("HEVC", .hevc),
        ("av1", .av1), ("vp9", .vp9),
        ("vc1", .vc1), ("mpeg2video", .mpeg2video), ("mpeg2", .mpeg2video),
    ])
    func videoCodecFromIdentifier(identifier: String, expected: VideoCodec) {
        #expect(VideoCodec(identifier: identifier) == expected)
    }

    @Test("VideoCodec rejects identifiers it doesn't know", arguments: ["unknown-codec", "", "vp8", "h26"])
    func videoCodecRejectsUnknown(identifier: String) {
        #expect(VideoCodec(identifier: identifier) == nil)
    }

    @Test("AudioCodec parses every accepted wire identifier", arguments: [
        ("aac", AudioCodec.aac), ("ac3", .ac3), ("AC-3", .ac3),
        ("eac3", .eac3), ("ec3", .eac3), ("E-AC-3", .eac3),
        ("flac", .flac), ("mp3", .mp3), ("opus", .opus),
        ("dts", .dts), ("dca", .dts), ("truehd", .trueHD), ("TrueHD", .trueHD),
    ])
    func audioCodecFromIdentifier(identifier: String, expected: AudioCodec) {
        #expect(AudioCodec(identifier: identifier) == expected)
    }

    @Test("AudioCodec rejects identifiers it doesn't know", arguments: ["pcm", "", "vorbis"])
    func audioCodecRejectsUnknown(identifier: String) {
        #expect(AudioCodec(identifier: identifier) == nil)
    }

    /// `avPlayerSupported` is the hinge the whole engine-selection story turns on, so it gets a
    /// membership test rather than being taken on trust from the codec list.
    @Test("avPlayerSupported holds the hardware-decodable audio codecs only")
    func avPlayerSupportedSet() {
        #expect(AudioCodec.avPlayerSupported == [.aac, .ac3, .eac3, .mp3])
        for codec in [AudioCodec.dts, .trueHD, .flac, .opus] {
            #expect(AudioCodec.avPlayerSupported.contains(codec) == false)
        }
    }

    /// The VLC-only codecs' raw values ARE their ffmpeg wire strings — the profile the device
    /// sends to Jellyfin is built from them, so a rename would silently change the negotiation.
    @Test("VLC-only video codecs keep their ffmpeg raw values")
    func videoCodecVLCOnlyRawValues() {
        #expect(VideoCodec.vc1.rawValue == "vc1")
        #expect(VideoCodec.mpeg2video.rawValue == "mpeg2video")
    }
}

@Suite("MediaStreamInfo helpers")
struct MediaStreamInfoHelperTests {
    private let en = Locale(identifier: "en_US")

    private func sub(
        _ codec: String?, title: String? = nil, streamTitle: String? = nil,
        language: String? = "eng", isExternal: Bool = false
    ) -> MediaStreamInfo {
        MediaStreamInfo(index: 1, kind: .subtitle, displayTitle: title, title: streamTitle,
                        language: language, codec: codec, channels: nil,
                        isExternal: isExternal, isForced: false, isDefault: false)
    }

    @Test("menuLabel falls through title→language→displayTitle→index, never leaking codec noise")
    func menuLabelFallback() {
        // The stream's own title wins outright.
        #expect(sub("subrip", title: "English - SUBRIP - Default",
                    streamTitle: "Signs & Songs").menuLabel(locale: en) == "Signs & Songs")
        // No title → the LOCALIZED language name, not the server's decorated string.
        #expect(sub("subrip", title: "English - SDH - Default").menuLabel(locale: en) == "English")
        // No title, no language → the display title, trimmed, " - Default" dropped.
        #expect(sub("subrip", title: "  English - SDH - Default  ",
                    language: nil).menuLabel(locale: en) == "English - SDH")
        let noLang = MediaStreamInfo(index: 4, kind: .audio, displayTitle: nil, language: nil,
                                     codec: nil, channels: nil, isExternal: false, isForced: false, isDefault: false)
        #expect(noLang.menuLabel(locale: en) == "Track 4")             // falls to index
    }

    @Test("trackDetailLabel composes codec/format · layout/source per kind")
    func detailLabel() {
        let audio = MediaStreamInfo(index: 1, kind: .audio, displayTitle: nil, language: "eng",
                                    codec: "truehd", channels: 8, isExternal: false,
                                    isForced: false, isDefault: true)
        #expect(audio.trackDetailLabel == "TrueHD · 7.1")
        #expect(sub("subrip", isExternal: true).trackDetailLabel == "SRT · External")
        #expect(sub("ass").trackDetailLabel == "ASS · Embedded")
        // Unknown codec still reports the source rather than dropping the line.
        #expect(sub(nil).trackDetailLabel == "Embedded")
    }

    /// Split per mapping (was one bundled test): a regression in the channel table used to hide
    /// behind an earlier codec-name failure in the same body.
    @Test("audio codec names read as the marketing name, falling back to an uppercased identifier",
          arguments: [
              ("eac3", nil, "Dolby Digital+"),
              ("ac3", nil, "Dolby Digital"),
              ("TRUEHD", nil, "TrueHD"),
              ("dts", "DTS-HD MA", "DTS-HD MA"),   // the profile is more specific than the codec
              ("dts", nil, "DTS"),
              ("pcm_s24le", nil, "PCM"),
              ("exotic", nil, "EXOTIC"),           // honest fallback, never a blank label
          ] as [(String, String?, String)])
    func audioCodecNames(codec: String, profile: String?, expected: String) {
        #expect(TrackDisplay.audioCodecName(codec: codec, profile: profile) == expected)
    }

    @Test("an absent audio codec has no name rather than an empty one")
    func audioCodecNameNil() {
        #expect(TrackDisplay.audioCodecName(codec: nil) == nil)
    }

    @Test("subtitle format names collapse ffmpeg spellings to the familiar label", arguments: [
        ("subrip", "SRT"), ("webvtt", "VTT"), ("mov_text", "Timed Text"), ("hdmv_pgs_subtitle", "PGS"),
    ])
    func subtitleFormatNames(codec: String, expected: String) {
        #expect(TrackDisplay.subtitleFormatName(codec) == expected)
    }

    @Test("an absent subtitle codec has no format name")
    func subtitleFormatNameNil() {
        #expect(TrackDisplay.subtitleFormatName(nil) == nil)
    }

    @Test("channel counts render as layouts, with a bare count for exotic ones", arguments: [
        (2, "Stereo"), (6, "5.1"), (8, "7.1"), (10, "10ch"),
    ])
    func channelLayouts(channels: Int, expected: String) {
        #expect(TrackDisplay.channelLayout(channels) == expected)
    }

    @Test("an unknown channel count has no layout")
    func channelLayoutNil() {
        #expect(TrackDisplay.channelLayout(nil) == nil)
    }

    @Test("language names localize, and the undetermined tag has none")
    func languageNames() {
        #expect(TrackDisplay.languageName("eng", locale: en) == "English")
        #expect(TrackDisplay.languageName("und", locale: en) == nil)
        #expect(TrackDisplay.languageName(nil, locale: en) == nil)
    }

    /// Underscore-separated tags carry the same script information as hyphenated
    /// ones — compared against the hyphenated rendering so the assertion holds in
    /// any locale.
    @Test("A script subtag survives either separator")
    func languageNameUnderscoreScript() {
        #expect(TrackDisplay.languageName("zh_Hans", locale: en) == TrackDisplay.languageName("zh-Hans", locale: en))
        #expect(TrackDisplay.languageName("zh_Hans", locale: en)?.contains("Simplified") == true)
        #expect(TrackDisplay.languageName("zh_Hant", locale: en) != TrackDisplay.languageName("zh_Hans", locale: en))
    }

    /// Driven by the shared list rather than a re-typed set of strings: the Jellyfin device
    /// profile declares one burn-in entry per identifier here, so anything the flag recognizes
    /// must be something the profile also declares, and vice versa.
    @Test("every shared image-subtitle codec identifier is flagged for burn-in",
          arguments: MediaStreamInfo.imageSubtitleCodecs)
    func imageSubtitleFormats(codec: String) {
        #expect(sub(codec).isImageSubtitle)
        #expect(sub(codec.uppercased()).isImageSubtitle, "servers report their own casing")
    }

    /// The flag is deliberately substring-tolerant beyond the exact profile list:
    /// a spelling variant misread as TEXT would get a sidecar URL built for a
    /// picture track and render nothing.
    @Test("image-subtitle spelling variants outside the profile list still classify as image",
          arguments: ["pgs", "pgs_subtitle", "hdmv_pgs"])
    func imageSubtitleSpellingVariants(codec: String) {
        #expect(sub(codec).isImageSubtitle)
    }

    /// An unknown codec must read as TEXT: mislabelling it as an image would force a burn-in
    /// transcode for a track the player could have rendered client-side.
    @Test("text and unknown subtitle formats are not image subtitles",
          arguments: ["subrip", "ass", "webvtt"])
    func textSubtitleFormats(codec: String) {
        #expect(sub(codec).isImageSubtitle == false)
    }

    @Test("a subtitle track with no codec is treated as text")
    func unknownSubtitleFormatIsText() {
        #expect(sub(nil).isImageSubtitle == false)
    }

    /// The detail line describes what a track is MADE OF; a video track (or an unclassified
    /// one) has nothing to say there, and an empty " · " would be worse than no line.
    @Test("video and other tracks have no detail label")
    func videoTracksHaveNoDetailLabel() {
        let video = MediaStreamInfo(index: 0, kind: .video, displayTitle: nil, language: nil,
                                    codec: "hevc", channels: nil, isExternal: false,
                                    isForced: false, isDefault: true)
        #expect(video.trackDetailLabel == nil)

        let other = MediaStreamInfo(index: 5, kind: .other, displayTitle: nil, language: nil,
                                    codec: "bin_data", channels: nil, isExternal: false,
                                    isForced: false, isDefault: false)
        #expect(other.trackDetailLabel == nil)
    }

    /// Track lists are rendered from these, so identity has to be the stream index — two
    /// same-named commentary tracks would otherwise collapse into one row.
    @Test("a stream is identified by its index")
    func identityIsTheStreamIndex() {
        #expect(sub("subrip").id == 1)
        let third = MediaStreamInfo(index: 3, kind: .audio, displayTitle: nil, language: nil,
                                    codec: nil, channels: nil, isExternal: false,
                                    isForced: false, isDefault: false)
        #expect(third.id == 3)
    }

    @Test("an audio track is never an image subtitle, whatever its codec string reads")
    func audioIsNeverAnImageSubtitle() {
        let audio = MediaStreamInfo(index: 1, kind: .audio, displayTitle: nil, language: nil,
                                    codec: "pgs", channels: nil, isExternal: false, isForced: false, isDefault: false)
        #expect(audio.isImageSubtitle == false)
    }
}

@Suite("TrackLanguage normalization")
struct TrackLanguageTests {
    @Test("Dialects of the same language all match: 639-1, 639-2 T, 639-2 B, BCP-47")
    func dialectsMatch() {
        #expect(TrackLanguage.matches("en", "eng"))
        #expect(TrackLanguage.matches("en-US", "eng"))
        #expect(TrackLanguage.matches("fr", "fre"))      // bibliographic
        #expect(TrackLanguage.matches("fra", "fre"))
        #expect(TrackLanguage.matches("de", "ger"))
        #expect(TrackLanguage.matches("zh-Hant", "chi"))
        #expect(TrackLanguage.matches("nld", "dut"))
    }

    @Test("Different languages and missing tags never match", arguments: [
        ("eng", "fra"), (nil, "eng"), ("eng", nil), (nil, nil), ("", "eng"),
    ] as [(String?, String?)])
    func mismatches(lhs: String?, rhs: String?) {
        #expect(TrackLanguage.matches(lhs, rhs) == false)
    }

    @Test("Unknown codes still match themselves (pass-through)")
    func unknownPassThrough() {
        #expect(TrackLanguage.normalized("qaa") == "qaa")
        #expect(TrackLanguage.matches("qaa", "QAA"))
    }

    /// Jellyfin persists culture rows with either separator ("zh-hans" from the
    /// server, "zh_Hans" from a muxer), so the primary subtag has to survive both.
    @Test("Underscore-separated tags normalize like hyphenated ones")
    func underscoreSeparator() {
        #expect(TrackLanguage.normalized("zh_Hans") == "zho")
        #expect(TrackLanguage.matches("zh_Hans", "chi"))
    }

    @Test("Script subtags are read out in canonical Titlecase", arguments: [
        ("zh-Hans", "Hans"), ("zh_hans", "Hans"), ("ZH-HANT", "Hant"),
        ("zh", nil), ("zh-CN", nil), ("en-US", nil), ("", nil), (nil, nil),
    ] as [(String?, String?)])
    func scriptSubtag(code: String?, expected: String?) {
        #expect(TrackLanguage.script(code) == expected)
    }
}
