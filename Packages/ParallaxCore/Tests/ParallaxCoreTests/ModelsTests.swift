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
}
