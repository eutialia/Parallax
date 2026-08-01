#if DEBUG
import Foundation

/// Append-only JSONL event log for Playback Lab runs, written to
/// `Documents/PlaybackLab/telemetry.jsonl` in the app container. The simulator
/// container is a plain host directory (`simctl get_app_container`), so the
/// driver script tails this file live while a run progresses instead of
/// waiting for the app to exit.
///
/// One JSON object per line, always carrying `t` (unix epoch seconds) and
/// `event`; everything else is event-specific. The unified-log stream
/// (category `vlc-audio`) is captured separately by the driver and merged by
/// timestamp — libvlc internals are deliberately NOT duplicated here.
actor PlaybackLabTelemetry {

    static let fileURL = URL.documentsDirectory.appending(path: "PlaybackLab/telemetry.jsonl")

    private let handle: FileHandle?

    init() {
        let url = Self.fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Truncate: one file per run, the driver copies it out before the next.
        manager.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func record(_ event: String, _ fields: [String: any Sendable] = [:]) {
        var line: [String: Any] = ["t": Date().timeIntervalSince1970, "event": event]
        line.merge(fields) { current, _ in current }
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
    }
}
#endif
