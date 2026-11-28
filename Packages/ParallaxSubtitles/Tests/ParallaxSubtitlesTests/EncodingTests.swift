import Foundation
import ParallaxSubtitles
import Testing

/// Authored files arrive in whatever encoding their author's system used. Each case draws a
/// file next to its UTF-8 twin, so a wrong decode shows as different glyphs.
@Suite("Encodings")
struct EncodingTests {
    static func drawings(of path: String) async throws -> [Drawing] {
        let subtitle = try await loaded(path)
        return try await [1.5, 2.5, 3.5].asyncMap { try await subtitle.drawing(at: $0) }
    }

    @Test("a GBK, Big5, Shift_JIS or EUC-KR authored file draws the same as its UTF-8 twin", arguments: [
        "gbk", "big5", "shift-jis", "euc-kr",
    ])
    func legacyEncodingDrawsLikeItsTwin(name: String) async throws {
        let legacy = try await Self.drawings(of: "legacy/\(name).ass")
        let twin = try await Self.drawings(of: "legacy/\(name).utf8.ass")

        #expect(twin.allSatisfy { !$0.isBlank })
        #expect(legacy == twin)
    }

    /// The damaged byte sits in a comment line of the header.
    @Test("a UTF-8 authored file with one damaged byte draws the same as the clean file")
    func oneDamagedByteDrawsLikeTheCleanFile() async throws {
        let clean = try await drawing(of: "utf8-clean.ass", at: 1.5)

        #expect(!clean.isBlank)
        #expect(try await drawing(of: "utf8-one-bad-byte.ass", at: 1.5) == clean)
    }

    @Test("a Latin-1 authored file is not drawn as Chinese")
    func latin1IsNotDrawnAsChinese() async throws {
        let twin = try await drawing(of: "latin1.utf8.ass", at: 1.5)

        #expect(!twin.isBlank)
        #expect(try await drawing(of: "latin1.ass", at: 1.5) == twin)
    }
}
