import Foundation

/// SubRip to ASS.
///
/// Deliberately forgiving: a sidecar that will not parse must degrade to "no
/// subtitles", never to a thrown error or junk on screen.
enum SRTToASSConverter {

    static func events(from source: String) -> [ASSEvent] {
        let text = CueMarkup.normalized(source)
        var events: [ASSEvent] = []

        var timing: (start: Double, end: Double)?
        var body: [String] = []

        /// - Parameter droppingTrailingIndex: set when the flush was triggered by
        ///   the next cue's timing line rather than by a blank separator. Files
        ///   that omit the blank line leave that cue's index number sitting at the
        ///   end of this cue's text, where it is an index and not dialogue. When a
        ///   blank line ended the cue, a trailing number is real text and stays.
        func flush(droppingTrailingIndex: Bool = false) {
            defer { timing = nil; body = [] }
            guard let timing else { return }
            if droppingTrailingIndex,
               let last = body.last,
               Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                body.removeLast()
            }
            let joined = body
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return }
            let tokens = CueMarkup.tokenize(joined, options: .init(decodesEntities: false))
            events.append(ASSEvent(start: timing.start, end: timing.end, text: CueMarkup.assText(tokens)))
        }

        // Line-at-a-time rather than block-at-a-time: real files skip the blank
        // separator often enough that splitting on it loses cues.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let parsed = CueMarkup.timing(fromLine: line) {
                flush(droppingTrailingIndex: true)
                timing = (parsed.start, parsed.end)
                continue
            }
            guard timing != nil else { continue }  // index lines and stray junk
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                body.append(String(line))
            }
        }
        flush()

        return events
    }

    static func script(from source: String, fontFamily: String) -> String {
        ASSScriptBuilder.script(events: events(from: source), fontFamily: fontFamily)
    }
}
