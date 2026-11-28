import Foundation

/// One line of a subtitle that arrives line by line, as a stream stored in the played file does.
public struct SubtitleLine: Hashable, Sendable {
    /// In the player's time.
    public let start: Duration
    public let duration: Duration
    /// As the file stores it: an ASS event's fields from `ReadOrder` on, or an SRT line's text.
    public let content: Data

    public init(start: Duration, duration: Duration, content: Data) {
        self.start = start
        self.duration = duration
        self.content = content
    }
}

public enum SubtitleLineFormat: Hashable, Sendable {
    /// `header` is the script up to its events.
    case ass(header: Data)
    case srt
}

/// A subtitle whose lines arrive while it plays.
public struct SubtitleLineStream: Sendable {
    public let format: SubtitleLineFormat
    /// Every line known so far, then each new line as it becomes known.
    public let lines: @Sendable () -> AsyncStream<[SubtitleLine]>

    public init(format: SubtitleLineFormat, lines: @escaping @Sendable () -> AsyncStream<[SubtitleLine]>) {
        self.format = format
        self.lines = lines
    }
}

/// Writes lines out as the file they would have been beside the video, so a subtitle stored in
/// the played file goes through the same load as one stored next to it.
enum SubtitleLineDocument {
    static func document(
        of lines: some Sequence<SubtitleLine>, format: SubtitleLineFormat
    ) -> (data: Data, format: SubtitleSourceFormat) {
        switch format {
        case .ass(let header): (ass(lines, after: header), .ass)
        case .srt: (srt(lines), .srt)
        }
    }

    // MARK: - ASS

    static let standardEventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
    /// The fields of a stored event after `ReadOrder`. Matroska fixes this order whatever the
    /// script's own event format is.
    static let storedFields = ["layer", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    /// Each event is written under the script's own event format, which the header keeps: a
    /// field the format names takes its stored value, and the two times come from the line.
    /// Events are written in read order, which is the order the script's author wrote them in
    /// and the one libass layers overlapping lines by.
    private static func ass(_ lines: some Sequence<SubtitleLine>, after header: Data) -> Data {
        var document = header
        if document.last != newline { document.append(newline) }
        let fields = eventFields(in: header) ?? {
            document.append(Data("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n".utf8))
            return standardEventFields
        }()

        let events = lines.compactMap { line -> (order: Int, line: SubtitleLine, stored: [String: Data])? in
            let parts = line.content.split(separator: comma, maxSplits: storedFields.count, omittingEmptySubsequences: false)
            guard parts.count == storedFields.count + 1, line.start + line.duration > .zero else { return nil }
            let order = Int(String(decoding: parts[0], as: UTF8.self).trimmingCharacters(in: .whitespaces)) ?? .max
            let values = parts.dropFirst().map { Data($0.filter { $0 != newline && $0 != carriageReturn }) }
            return (order, line, Dictionary(uniqueKeysWithValues: zip(storedFields, values)))
        }
        let inReadOrder = events.sorted {
            ($0.order, $0.line.start) != ($1.order, $1.line.start)
                ? ($0.order, $0.line.start) < ($1.order, $1.line.start)
                : $0.line.content.lexicographicallyPrecedes($1.line.content)
        }
        for event in inReadOrder {
            let written = fields.map { field -> Data in
                switch field {
                case "start": Data(timecode(max(.zero, event.line.start)).utf8)
                case "end": Data(timecode(event.line.start + event.line.duration).utf8)
                // An SSA script's name for the field Matroska stores as the layer.
                case "marked": event.stored["layer"] ?? Data()
                default: event.stored[field] ?? Data()
                }
            }
            document.append(Data("Dialogue: ".utf8))
            document.append(Data(written.joined(separator: [comma])))
            document.append(newline)
        }
        return document
    }

    /// The names in the `Format:` line of the script's `[Events]` section, lowercased. Nil when
    /// the header has none.
    static func eventFields(in header: Data) -> [String]? {
        var inEvents = false
        for line in String(decoding: header, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
            } else if inEvents, trimmed.lowercased().hasPrefix("format:") {
                return trimmed.dropFirst("format:".count).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
        }
        return nil
    }

    /// `H:MM:SS.cc`, the only precision an ASS event has.
    static func timecode(_ time: Duration) -> String {
        let centiseconds = Int((time / .milliseconds(10)).rounded())
        return String(
            format: "%d:%02d:%02d.%02d", centiseconds / 360_000, centiseconds / 6000 % 60, centiseconds / 100 % 60,
            centiseconds % 100)
    }

    // MARK: - SRT

    /// A line's text keeps its line breaks and loses its blank lines: in an SRT file a blank
    /// line ends the cue.
    private static func srt(_ lines: some Sequence<SubtitleLine>) -> Data {
        var document = Data()
        let shown = lines.filter { $0.start + $0.duration > .zero }.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.content.lexicographicallyPrecedes($1.content)
        }
        for (index, line) in shown.enumerated() {
            let text = line.content.split(separator: newline)
                .map { $0.last == carriageReturn ? $0.dropLast() : $0 }
                .filter { !$0.allSatisfy { $0 == space || $0 == tab } }
            guard !text.isEmpty else { continue }
            let end = line.start + line.duration
            document.append(Data("\(index + 1)\n\(srtTime(max(.zero, line.start))) --> \(srtTime(end))\n".utf8))
            document.append(Data(text.joined(separator: [newline])))
            document.append(contentsOf: [newline, newline])
        }
        return document
    }

    static func srtTime(_ time: Duration) -> String {
        let milliseconds = Int((time / .milliseconds(1)).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
            milliseconds / 1000 % 60, milliseconds % 1000)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let comma = UInt8(ascii: ",")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
}
