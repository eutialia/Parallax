#if DEBUG
import Foundation
import OSLog
import MobileVLCKit

/// DEBUG-only tap on libvlc's log stream that mirrors audio-pipeline messages
/// into the unified log (subsystem `com.lhdev.parallax`, category `vlc-audio`).
///
/// When an elementary stream falls behind the clock, libvlc pauses just that
/// stream — for audio that means inserting silence ("audio output is starving",
/// "playing silence", "inserting N zeroes") while video keeps going. None of
/// that surfaces through VLCKit's delegate API, so a periodic audio dropout is
/// indistinguishable from a decoder failure without this tap. To capture a
/// repro, filter Console (or the Xcode console) on category `vlc-audio` and
/// match the line timestamps against the audible gaps.
///
/// Installed once next to the events configuration — see `VLCKitEngine`.
///
/// VLC calls `handleMessage` from its own internal threads; the logger is
/// immutable after setup and `Logger` is thread-safe, hence `@unchecked Sendable`.
final class VLCAudioDiagnosticsLogger: NSObject, VLCLogging, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.lhdev.parallax", category: "vlc-audio")

    /// VLCKit applies this as its own filter before invoking the handler —
    /// receive everything and let `handleMessage` do the narrowing.
    var level: VLCLogLevel = .debug

    /// Message substrings that mark audio/clock trouble regardless of module.
    /// "clock source" catches es_out's one-line master/slave verdict; "starting
    /// late"/"deferring start" are avsamplebuffer's renderer-start timing — the
    /// starting-late value is the constant lateness the flush loop then chases.
    private static let keywords = [
        "starving", "silence", "zeroes", "resampl", "drift",
        "underflow", "underrun", "out of sync", "too early", "too late",
        "clock source", "starting late", "deferring start", "audio output module",
    ]

    /// Modules that own the audio output and clock pipeline.
    private static let audioModules = ["aout", "audiotoolbox", "audiounit", "avsamplebuffer", "clock"]

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? ""
        // Errors and warnings pass unfiltered — a decoder/aout open failure is
        // the "no audio at all" case. Info/debug only when audio-related.
        if level == .debug || level == .info {
            let isAudioModule = Self.audioModules.contains { module.contains($0) }
            let lowered = message.lowercased()
            guard isAudioModule || Self.keywords.contains(where: { lowered.contains($0) }) else {
                return
            }
        }
        switch level {
        case .error:
            Self.log.error("[\(module, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            Self.log.warning("[\(module, privacy: .public)] \(message, privacy: .public)")
        default:
            Self.log.debug("[\(module, privacy: .public)] \(message, privacy: .public)")
        }
    }
}
#endif
