import Foundation
import CoreMedia

/// A single timed subtitle cue: when to show `text` and until when.
///
/// Times are `CMTime` (timescale 1000) so they compare directly against the
/// player clock with no conversion layer.
public struct SubtitleCue: Sendable, Hashable {
    public let start: CMTime
    public let end: CMTime
    public let text: String

    public init(start: CMTime, end: CMTime, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A dependency-free WebVTT parser.
///
/// Built for Jellyfin's dedicated subtitle endpoint
/// (`/Videos/…/Subtitles/{i}/Stream.vtt?copyTimestamps=true`), which emits
/// **absolute** cue timestamps. We deliberately ignore any `X-TIMESTAMP-MAP`
/// header: applying it is exactly the segmented-WebVTT drift bug
/// (jellyfin/jellyfin#16647) this whole path exists to avoid.
///
/// Lives in `ParallaxPlayback` (no SwiftUI/Combine, no platform conditionals),
/// so it's unit-testable on the iOS simulator.
public enum WebVTTParser {

    public static func parse(data: Data) -> [SubtitleCue] {
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return parse(string)
    }

    /// Parses a WebVTT document into time-ordered cues. Returns `[]` for empty
    /// or non-WebVTT input rather than throwing — a missing/garbled subtitle
    /// must never break playback.
    public static func parse(_ string: String) -> [SubtitleCue] {
        // Normalize newlines, then split into blocks on blank lines.
        let normalized = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            // Skip non-cue blocks (the WEBVTT header, NOTE/STYLE/REGION sections).
            // A timing line wins over these markers only if it precedes them, but
            // a header/NOTE block never contains "-->", so a guard on the first
            // meaningful line is enough.
            let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if firstLine.hasPrefix("WEBVTT") || firstLine.hasPrefix("NOTE")
                || firstLine.hasPrefix("STYLE") || firstLine.hasPrefix("REGION") {
                continue
            }

            guard let (start, end) = parseTiming(lines[timingIndex]) else { continue }

            // Everything after the timing line is cue text (lines before it are an
            // optional cue identifier, which we ignore).
            let textLines = lines[(timingIndex + 1)...]
            let text = renderText(textLines.joined(separator: "\n"))
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: text))
        }

        return cues.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    }

    // MARK: - Timing

    /// Parses a `00:00:01.000 --> 00:00:04.000 align:start position:50%` line.
    /// Cue-setting tokens after the end timestamp are dropped.
    private static func parseTiming(_ line: String) -> (CMTime, CMTime)? {
        let halves = line.components(separatedBy: "-->")
        guard halves.count == 2,
              let start = parseTimestamp(halves[0].trimmingCharacters(in: .whitespaces))
        else { return nil }

        // The end side may carry trailing cue settings: take the first token.
        let endToken = halves[1].trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let end = parseTimestamp(endToken) else { return nil }
        return (start, end)
    }

    /// Parses `HH:MM:SS.mmm` or `MM:SS.mmm` (also tolerates `,` as the decimal
    /// separator) into a `CMTime` at timescale 1000.
    private static func parseTimestamp(_ raw: String) -> CMTime? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var hours = 0.0
        let minutes: Double
        let seconds: Double
        if parts.count == 3 {
            guard let h = Double(parts[0]) else { return nil }
            hours = h
            guard let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            minutes = m; seconds = s
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            minutes = m; seconds = s
        }
        let total = hours * 3600 + minutes * 60 + seconds
        guard total.isFinite, total >= 0 else { return nil }
        return CMTime(value: CMTimeValue((total * 1000).rounded()), timescale: 1000)
    }

    // MARK: - Text

    /// Strips inline tags (`<i>`, `<b>`, `<c.classname>`, `<v Speaker>`, `<00:00:01.000>`…)
    /// and decodes the core WebVTT entities. Tag stripping runs BEFORE entity
    /// decoding so a decoded `<`/`>` can't be mistaken for markup.
    private static func renderText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "<[^>]*>",
            with: "",
            options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: "&lrm;", with: "")
            .replacingOccurrences(of: "&rlm;", with: "")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")   // last: avoids double-decoding
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
