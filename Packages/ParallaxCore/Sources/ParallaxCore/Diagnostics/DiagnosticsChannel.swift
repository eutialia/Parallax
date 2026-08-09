import Foundation
import os

/// A logging channel that writes to BOTH Console (`os.Logger`) and the retained on-device file
/// (`DiagnosticsLog`).
///
/// **Why it's a separate type from `Log.custom`.** `Logger` interpolation carries privacy specifiers
/// and defers formatting into the unified log; that machinery can't be re-pointed at a file, and
/// rewriting a hundred existing `Log.*` call sites to lose it would be a downgrade. So the retained
/// file gets its own, deliberately narrower door: plain `String` messages, chosen one call site at a
/// time. What lands in the file is what someone decided is worth surviving the process — not
/// everything the app has ever logged.
///
/// **Redaction is the caller's job, same as Console.** This file is meant to be exported and sent to
/// a stranger, so wrap secrets in `Redacted` and URLs in `redactedForLog` before interpolating.
public struct DiagnosticsChannel: Sendable {

    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.logger = Log.custom(category: category)
    }

    /// Routine progress, Console ONLY — see `DiagnosticsLevel.isRetained`. Use it for the records
    /// that help while watching a live session but would flood a byte-capped file.
    public func info(_ message: @autoclosure () -> String) {
        write(.info, message)
    }

    /// A state change worth finding at a glance — a foreground return, a pool flush, a condemnation.
    /// The first level that is RETAINED: saying `notice` is saying "this must survive the process".
    public func notice(_ message: @autoclosure () -> String) {
        write(.notice, message)
    }

    /// Something failed, and the failure is part of the story.
    public func error(_ message: @autoclosure () -> String) {
        write(.error, message)
    }

    /// An invariant this code believes cannot break, breaking.
    public func fault(_ message: @autoclosure () -> String) {
        write(.fault, message)
    }

    /// A milestone: wall-clock time and memory headroom on top of the usual record.
    ///
    /// Reserved for the few edges where the real-world moment matters (scene phase, pool flush) —
    /// which makes it also the right place to carry vitals. A process killed by jetsam leaves no
    /// crash record of any kind, so the only way to recognise one afterwards is a last record whose
    /// headroom had collapsed. Attaching it here costs two syscalls at a handful of edges.
    public func mark(_ message: @autoclosure () -> String) {
        let text = "\(message()) \(DiagnosticsVitals.summary())"
        logger.log(level: .default, "\(text, privacy: .public)")
        DiagnosticsLog.recordWithWallClock(category: category) { text }
    }

    private func write(_ level: DiagnosticsLevel, _ message: () -> String) {
        // Formatted once and handed to both sinks: the message closure may be doing real work
        // (describing an error, formatting a count) and must not run twice.
        let text = message()
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
        DiagnosticsLog.record(category: category, level: level) { text }
    }
}

public extension Log {
    /// A retained channel for `category` — Console *and* the on-device diagnostics file. Use this
    /// (rather than `Log.custom`) for the lifecycle facts that have to survive a crash; `Log.custom`
    /// stays right for everything whose only reader is a live Console session.
    static func retained(category: String) -> DiagnosticsChannel {
        DiagnosticsChannel(category: category)
    }
}
