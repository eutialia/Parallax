import Foundation
import CoreMedia

/// A dependency-free SubRip (SRT) parser.
///
/// Produces the same `SubtitleCue` type `WebVTTParser` emits so the
/// `activeSubtitleCues` → `SubtitleOverlayView` path works unchanged for
/// filename-matched SRT sidecar files on SMB.
///
/// Handles:
/// - `HH:MM:SS,mmm --> HH:MM:SS,mmm` timecodes (comma OR period as the
///   millisecond separator — non-standard period is tolerated).
/// - Index lines before the timecode (skipped as cue identifiers).
/// - Multi-line cue text accumulated until the next blank line.
/// - CRLF and bare CR line endings (normalized to LF).
/// - UTF-8 BOM stripped before parsing.
///
/// Returns `[]` for empty or non-SRT input rather than throwing — a
/// missing/garbled subtitle must never break playback.
public enum SRTParser {

    public static func parse(data: Data) -> [SubtitleCue] {
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return parse(string)
    }

    public static func parse(_ string: String) -> [SubtitleCue] {
        // Strip UTF-8 BOM if present.
        let stripped = string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string

        // Normalize line endings, then split into blocks on blank lines.
        let normalized = stripped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !lines.isEmpty else { continue }

            // Find the timing line (contains "-->"). In valid SRT it's the second
            // line (after the sequence number), but we scan to be tolerant.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            guard let (start, end) = parseTiming(lines[timingIndex]) else { continue }

            // Everything after the timing line is cue text. Lines before it
            // (the sequence number / any cue identifier) are ignored.
            let textLines = lines[(timingIndex + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: text))
        }

        return cues.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    }

    // MARK: - Timing

    /// Parses `HH:MM:SS,mmm --> HH:MM:SS,mmm`.
    private static func parseTiming(_ line: String) -> (CMTime, CMTime)? {
        let halves = line.components(separatedBy: "-->")
        guard halves.count == 2,
              let start = parseTimestamp(halves[0].trimmingCharacters(in: .whitespaces)),
              let end = parseTimestamp(halves[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (start, end)
    }

    /// Parses `HH:MM:SS,mmm` (also accepts `.` as the decimal separator) into
    /// a `CMTime` at timescale 1000.
    private static func parseTimestamp(_ raw: String) -> CMTime? {
        // Normalize comma → period for Double parsing.
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }

        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }

        let total = h * 3600 + m * 60 + s
        guard total.isFinite, total >= 0 else { return nil }
        return CMTime(value: CMTimeValue((total * 1000).rounded()), timescale: 1000)
    }
}
