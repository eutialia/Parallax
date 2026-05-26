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
