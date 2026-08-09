import Foundation
import Testing
@testable import ParallaxCore

/// Covers the three pieces of the retained-log design that carry a real decision: what survives the
/// byte cap, what is retained at all, and what a browser gets back from the tvOS handoff.
///
/// `DiagnosticsLog.start()` itself is deliberately untested: it opens ONE process-wide sink and arms
/// signal handlers, so exercising it would leak into every other suite in the run and could not be
/// undone. Its two decisions that matter in isolation — the retained-level floor and the crash-marker
/// scan — are reachable directly, and they are what these tests drive.
@Suite("Diagnostics")
struct DiagnosticsTests {

    // MARK: - Level policy

    /// The floor that keeps a scrolling wall from evicting a crash. Parameterised because the whole
    /// point is the BOUNDARY between `info` and `notice`, and asserting it one level at a time is how
    /// a future level gets classified deliberately instead of by accident.
    @Test("only notice and above reach the retained file", arguments: [
        (DiagnosticsLevel.debug, false),
        (DiagnosticsLevel.info, false),
        (DiagnosticsLevel.notice, true),
        (DiagnosticsLevel.error, true),
        (DiagnosticsLevel.fault, true),
    ])
    func retainedLevels(level: DiagnosticsLevel, isRetained: Bool) {
        #expect(level.isRetained == isRetained)
    }

    // MARK: - Sink byte cap

    @Test("the sink writes records straight through to the file")
    func sinkAppends() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try #require(DiagnosticsSink(url: url))

        sink.append("first")
        sink.append("second")

        #expect(try String(contentsOf: url, encoding: .utf8) == "first\nsecond\n")
    }

    /// The cap has to stop the flood WITHOUT going silent about it — a log that just ends looks
    /// identical to a process that died, which is the one thing this file exists to tell apart.
    @Test("the cap truncates once, says so, and drops the rest")
    func sinkCapAnnouncesItselfExactlyOnce() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try #require(DiagnosticsSink(url: url))

        // Overshoot the cap several times over, so there are many records that must be dropped after
        // the notice rather than one.
        let record = String(repeating: "x", count: 1024)
        for _ in 0..<(DiagnosticsSink.recordByteCap / 1024 + 32) {
            sink.append(record)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let notices = text.components(separatedBy: "log full at").count - 1
        #expect(notices == 1)
        #expect(text.hasSuffix("crash reports still recorded ---\n"))
    }

    /// A crash report is written by a signal handler that cannot consult the cap, and must land even
    /// when ordinary records have already been cut off.
    @Test("uncapped writes still land after the cap has closed")
    func sinkUncappedBypassesTheCap() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try #require(DiagnosticsSink(url: url))

        let record = String(repeating: "x", count: 1024)
        for _ in 0..<(DiagnosticsSink.recordByteCap / 1024 + 2) {
            sink.append(record)
        }
        // A sentinel that shares no words with the truncation notice — "dropped" appears in the
        // notice itself, so it cannot witness a record having been dropped.
        sink.append("SENTINEL-ORDINARY-RECORD")
        sink.appendUncapped("\(CrashSentinel.crashMarker) signal=SIGSEGV")

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("SENTINEL-ORDINARY-RECORD"))
        #expect(text.contains(CrashSentinel.crashMarker))
    }

    // MARK: - Crash detection

    @Test("a session that crashed is recognised by its marker line")
    func crashSummaryFindsTheMarker() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [+  0.001] N [AppLifecycle] main launch
        \(CrashSentinel.crashMarker) signal=SIGSEGV code=2 address=0x1
        0   Parallax  0x00000001 main + 4
        """.write(to: url, atomically: true, encoding: .utf8)

        let summary = DiagnosticsLog.crashSummary(of: url)
        #expect(summary?.contains("signal=SIGSEGV") == true)
        // The LINE, not the whole file — the row that shows it has one line of space.
        #expect(summary?.contains("main + 4") == false)
    }

    @Test("a clean session reports no crash")
    func crashSummaryAbsentOnCleanSession() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try "[+  0.001] N [AppLifecycle] main launch\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(DiagnosticsLog.crashSummary(of: url) == nil)
    }

    // MARK: - tvOS handoff responses

    /// The trailing slash and the query string are both things a browser or a person adds without
    /// meaning to; refusing them would read as a mistyped token.
    @Test("the token path serves the log", arguments: ["/tok0", "/tok0/", "/tok0?utm=x"])
    func handoffServesTheTokenPath(path: String) {
        let response = Self.handoffResponse(method: "GET", path: path)
        #expect(response.contains("200 OK"))
        #expect(response.contains("PAYLOAD"))
    }

    /// The whole point of the token: the log carries host names, share names and a usage timeline,
    /// so a device that never saw the screen must not be able to guess its way in. `/favicon.ico` is
    /// included because a browser fetches it unprompted.
    @Test(
        "every other path is refused, including a near-miss token",
        arguments: ["/", "/anything", "/favicon.ico", "/tok1", "/tok0x", "/TOK0"]
    )
    func handoffRefusesEveryOtherPath(path: String) {
        let response = Self.handoffResponse(method: "GET", path: path)
        #expect(response.contains("404 Not Found"))
        #expect(!response.contains("PAYLOAD"))
    }

    @Test("HEAD is answered without a body, so a probe doesn't pull the whole file")
    func handoffHeadOmitsTheBody() {
        let response = Self.handoffResponse(method: "HEAD", path: "/tok0")
        #expect(response.contains("200 OK"))
        #expect(response.contains("Content-Length: 7"))
        #expect(!response.contains("PAYLOAD"))
    }

    @Test("a write method is refused rather than ignored", arguments: ["POST", "PUT", "DELETE"])
    func handoffRefusesWrites(method: String) {
        #expect(Self.handoffResponse(method: method, path: "/tok0").contains("405 Method Not Allowed"))
    }

    @Test("a malformed request line gets a 400 instead of the log")
    func handoffRejectsMalformedRequests() {
        let response = DiagnosticsHandoffServer.response(
            for: "GARBAGE\r\n\r\n", fileName: "log.txt", payload: Data("PAYLOAD".utf8), token: "tok0"
        )
        #expect(String(decoding: response, as: UTF8.self).contains("400 Bad Request"))
    }

    // MARK: - Helpers

    private static func handoffResponse(method: String, path: String) -> String {
        let head = "\(method) \(path) HTTP/1.1\r\nHost: x\r\n\r\n"
        let response = DiagnosticsHandoffServer.response(
            for: head, fileName: "log.txt", payload: Data("PAYLOAD".utf8), token: "tok0"
        )
        return String(decoding: response, as: UTF8.self)
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString).log")
    }
}

@Suite("Diagnostics redaction")
struct DiagnosticsRedactionTests {

    /// Share roots must stay legible — redacting them would make every root listing look like a
    /// hidden path and cost the log its most common record for nothing.
    @Test("a path with nothing to hide is returned untouched", arguments: ["", "/"])
    func rootPathsAreUntouched(path: String) {
        #expect(DiagnosticsRedaction.path(path) == path)
    }

    @Test(
        "depth survives, names do not",
        arguments: [
            ("/Anime", 1),
            ("/Anime/Series", 2),
            ("Anime/Series/Season 1", 3),
            ("\\Anime\\Series", 2),
        ]
    )
    func depthIsReportedAndNamesAreDropped(path: String, depth: Int) {
        let redacted = DiagnosticsRedaction.path(path)
        #expect(redacted.hasPrefix("/…\(depth)#"))
        // The whole point: no fragment of the original may survive into the log.
        for component in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            #expect(!redacted.contains(component))
        }
    }

    /// Correlating two records as "the same folder" is the one thing the digest is FOR, so equal
    /// inputs must agree within a process.
    @Test("equal paths redact identically, different paths do not")
    func digestsCorrelateWithinAProcess() {
        let title = "/[Group] Some Series [01-13][WebRip 1080p]"
        #expect(DiagnosticsRedaction.path(title) == DiagnosticsRedaction.path(title))
        #expect(DiagnosticsRedaction.path(title) != DiagnosticsRedaction.path(title + "/Extras"))
    }

    /// Same depth, different content — proves the token is doing the distinguishing rather than the
    /// depth prefix carrying the whole signal.
    @Test("same-depth paths are still told apart")
    func sameDepthPathsDiffer() {
        #expect(DiagnosticsRedaction.path("/Movies") != DiagnosticsRedaction.path("/Shows"))
    }
}
