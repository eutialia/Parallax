import Foundation
import Testing
@testable import ParallaxCore

@Suite("Bytes value type")
struct BytesTests {
    @Test("Bytes formats as a human-readable string for common scales")
    func humanReadable() {
        #expect(Bytes(rawValue: 0).formatted() == "0 B")
        #expect(Bytes(rawValue: 1_500).formatted() == "1.5 KB")
        #expect(Bytes(rawValue: 1_500_000).formatted() == "1.5 MB")
        #expect(Bytes(rawValue: 1_500_000_000).formatted() == "1.5 GB")
    }

    @Test("Bytes is comparable")
    func comparable() {
        #expect(Bytes(rawValue: 100) < Bytes(rawValue: 200))
        #expect(Bytes(rawValue: 200) > Bytes(rawValue: 100))
        #expect(Bytes(rawValue: 100) == Bytes(rawValue: 100))
    }

    @Test("Bytes round-trips through Codable")
    func codableRoundTrip() throws {
        let original = Bytes(rawValue: 1_234_567)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Bytes.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("Bitrate value type")
struct BitrateTests {
    @Test("Bitrate constructs from convenience factory methods")
    func factories() {
        #expect(Bitrate.bitsPerSecond(8_000_000).rawValue == 8_000_000)
        #expect(Bitrate.kilobits(1_000).rawValue == 1_000_000)
        #expect(Bitrate.megabits(8).rawValue == 8_000_000)
    }

    @Test("Bitrate formats as a human-readable string")
    func humanReadable() {
        #expect(Bitrate.megabits(8).formatted() == "8 Mbps")
        #expect(Bitrate.kilobits(500).formatted() == "500 kbps")
        #expect(Bitrate.bitsPerSecond(500).formatted() == "500 bps")
    }

    @Test("Bitrate caps non-integer values to one fractional digit")
    func boundedDecimals() {
        // 8_333_333 bps → 8.333333 Mbps → "8.3 Mbps", not full Double precision
        #expect(Bitrate(rawValue: 8_333_333).formatted() == "8.3 Mbps")
        #expect(Bitrate(rawValue: 8_500_000).formatted() == "8.5 Mbps")
        // Integer-valued cases drop the fractional digit
        #expect(Bitrate(rawValue: 2_000_000).formatted() == "2 Mbps")
    }

    @Test("Bitrate is comparable")
    func comparable() {
        #expect(Bitrate.megabits(4) < Bitrate.megabits(8))
        #expect(Bitrate.megabits(8) == Bitrate.megabits(8))
    }
}

@Suite("FilePath value type")
struct FilePathTests {
    @Test("FilePath constructs from string components")
    func fromString() {
        let path = FilePath("/Media/Movies/Inception.mkv")
        #expect(path.components == ["Media", "Movies", "Inception.mkv"])
    }

    @Test("FilePath handles leading and trailing slashes")
    func trimsSlashes() {
        #expect(FilePath("/Media/").components == ["Media"])
        #expect(FilePath("Media").components == ["Media"])
        #expect(FilePath("").components == [])
        #expect(FilePath("/").components == [])
    }

    @Test("FilePath appending produces a new path")
    func appending() {
        let parent = FilePath("/Media")
        let child = parent.appending("Movies")
        #expect(child.components == ["Media", "Movies"])
        #expect(child.appending("Inception.mkv").components == ["Media", "Movies", "Inception.mkv"])
    }

    @Test("FilePath renders to string with leading slash")
    func rendersToString() {
        #expect(FilePath("/Media/Movies").rendered == "/Media/Movies")
        #expect(FilePath("").rendered == "/")
    }

    @Test("FilePath parent returns container directory")
    func parent() {
        #expect(FilePath("/Media/Movies/Inception.mkv").parent?.rendered == "/Media/Movies")
        #expect(FilePath("/Media").parent?.rendered == "/")
        #expect(FilePath("/").parent == nil)
    }
}

@Suite("MediaInfo enums")
struct MediaInfoTests {
    @Test("Container enum covers expected values")
    func containerCases() {
        #expect(Container.allCases.contains(.mp4))
        #expect(Container.allCases.contains(.mkv))
        #expect(Container.allCases.contains(.hls))
    }

    @Test("VideoCodec parses from common identifier strings")
    func videoCodecFromIdentifier() {
        #expect(VideoCodec(identifier: "h264") == .h264)
        #expect(VideoCodec(identifier: "hevc") == .hevc)
        #expect(VideoCodec(identifier: "H.264") == .h264)
        #expect(VideoCodec(identifier: "HEVC") == .hevc)
        #expect(VideoCodec(identifier: "av1") == .av1)
        #expect(VideoCodec(identifier: "unknown-codec") == nil)
    }

    @Test("AudioCodec parses common identifiers")
    func audioCodecFromIdentifier() {
        #expect(AudioCodec(identifier: "aac") == .aac)
        #expect(AudioCodec(identifier: "eac3") == .eac3)
        #expect(AudioCodec(identifier: "ac3") == .ac3)
        #expect(AudioCodec(identifier: "flac") == .flac)
        #expect(AudioCodec(identifier: "dts") == .dts)
        #expect(AudioCodec(identifier: "truehd") == .trueHD)
    }

    @Test("HDRSupport composes as an OptionSet")
    func hdrOptionSet() {
        #expect(HDRSupport.dolbyVision.includes(.dolbyVision))
        #expect(HDRSupport.both.includes(.hdr10))
        #expect(HDRSupport.both.includes(.dolbyVision))
        #expect(HDRSupport.hdr10.includes(.hdr10))
        #expect(!HDRSupport.hdr10.includes(.dolbyVision))
        #expect(!HDRSupport.none.includes(.hdr10))
    }

    @Test("HDRSupport covers HDR10+ and combinations")
    func hdr10PlusCombinations() {
        let modern: HDRSupport = [.hdr10, .hdr10Plus, .dolbyVision]
        #expect(modern.includes(.hdr10Plus))
        #expect(modern.includes(.hdr10))
        #expect(modern.includes(.dolbyVision))
        #expect(modern.includes([.hdr10, .dolbyVision]))
        #expect(!HDRSupport.hdr10.includes(.hdr10Plus))
    }

    @Test("HDRSupport round-trips through Codable")
    func hdrCodable() throws {
        let original: HDRSupport = [.hdr10, .hdr10Plus, .dolbyVision]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HDRSupport.self, from: data)
        #expect(decoded == original)
    }

    @Test("VideoCodec has vc1 and mpeg2video cases")
    func videoCodecVLCOnlyCases() {
        // Compile-time proof the cases exist.
        let codecs: [VideoCodec] = [.vc1, .mpeg2video]
        #expect(codecs.count == 2)
        #expect(VideoCodec.vc1.rawValue == "vc1")
        #expect(VideoCodec.mpeg2video.rawValue == "mpeg2video")
    }

    @Test("VideoCodec.init?(identifier:) parses vc1 and mpeg2video wire strings")
    func videoCodecIdentifierVLC() {
        #expect(VideoCodec(identifier: "vc1") == .vc1)
        #expect(VideoCodec(identifier: "mpeg2video") == .mpeg2video)
        #expect(VideoCodec(identifier: "mpeg2") == .mpeg2video)
    }

    @Test("Container.avi exists and rawValue is 'avi'")
    func aviRawValue() {
        #expect(Container.avi.rawValue == "avi")
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

    @Test("TrackDisplay maps codec identifiers to listener-facing names")
    func trackDisplayNames() {
        #expect(TrackDisplay.audioCodecName(codec: "eac3") == "Dolby Digital+")
        #expect(TrackDisplay.audioCodecName(codec: "ac3") == "Dolby Digital")
        #expect(TrackDisplay.audioCodecName(codec: "TRUEHD") == "TrueHD")
        #expect(TrackDisplay.audioCodecName(codec: "dts", profile: "DTS-HD MA") == "DTS-HD MA")
        #expect(TrackDisplay.audioCodecName(codec: "dts", profile: nil) == "DTS")
        #expect(TrackDisplay.audioCodecName(codec: "pcm_s24le") == "PCM")
        #expect(TrackDisplay.audioCodecName(codec: "exotic") == "EXOTIC")   // honest fallback
        #expect(TrackDisplay.audioCodecName(codec: nil) == nil)

        #expect(TrackDisplay.subtitleFormatName("subrip") == "SRT")
        #expect(TrackDisplay.subtitleFormatName("webvtt") == "VTT")
        #expect(TrackDisplay.subtitleFormatName("mov_text") == "Timed Text")
        #expect(TrackDisplay.subtitleFormatName("hdmv_pgs_subtitle") == "PGS")
        #expect(TrackDisplay.subtitleFormatName(nil) == nil)

        #expect(TrackDisplay.channelLayout(2) == "Stereo")
        #expect(TrackDisplay.channelLayout(6) == "5.1")
        #expect(TrackDisplay.channelLayout(8) == "7.1")
        #expect(TrackDisplay.channelLayout(10) == "10ch")
        #expect(TrackDisplay.channelLayout(nil) == nil)

        #expect(TrackDisplay.languageName("eng", locale: en) == "English")
        #expect(TrackDisplay.languageName("und", locale: en) == nil)
        #expect(TrackDisplay.languageName(nil, locale: en) == nil)
    }

    @Test("isImageSubtitle flags burn-in-only formats and clears text formats")
    func imageSubtitleClassification() {
        #expect(sub("PGSSUB").isImageSubtitle)
        #expect(sub("hdmv_pgs_subtitle").isImageSubtitle)
        #expect(sub("vobsub").isImageSubtitle)
        #expect(sub("dvd_subtitle").isImageSubtitle)
        #expect(!sub("subrip").isImageSubtitle)
        #expect(!sub("ass").isImageSubtitle)
        #expect(!sub("webvtt").isImageSubtitle)
        #expect(!sub(nil).isImageSubtitle)                             // unknown → treat as text
        // Audio is never an image subtitle, whatever the codec string.
        let audio = MediaStreamInfo(index: 1, kind: .audio, displayTitle: nil, language: nil,
                                    codec: "pgs", channels: nil, isExternal: false, isForced: false, isDefault: false)
        #expect(!audio.isImageSubtitle)
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

    @Test("Different languages and missing tags never match")
    func mismatches() {
        #expect(!TrackLanguage.matches("eng", "fra"))
        #expect(!TrackLanguage.matches(nil, "eng"))
        #expect(!TrackLanguage.matches("eng", nil))
        #expect(!TrackLanguage.matches(nil, nil))
        #expect(!TrackLanguage.matches("", "eng"))
    }

    @Test("Unknown codes still match themselves (pass-through)")
    func unknownPassThrough() {
        #expect(TrackLanguage.normalized("qaa") == "qaa")
        #expect(TrackLanguage.matches("qaa", "QAA"))
    }
}
