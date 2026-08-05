import Foundation

/// WebVTT to ASS.
///
/// Unlike the usual ffmpeg conversion, cue settings are carried over instead of
/// discarded: `line:`, `position:` and `align:` decide the ASS alignment corner
/// and, when a percentage is involved, an explicit `\pos`. Cues with no settings
/// are left unpositioned on purpose so libass' collision handling keeps
/// simultaneous cues stacked rather than overlapping.
enum WebVTTToASSConverter {

    // MARK: - Cue settings

    struct CueSettings: Equatable {
        enum Line: Equatable {
            /// Fraction of the picture height, 0 = top.
            case percent(Double)
            /// Line index; negative counts from the bottom.
            case number(Int)
        }

        var align: String?
        /// Percentage across the picture, 0 = left edge.
        var position: Double?
        var line: Line?

        var isEmpty: Bool { align == nil && position == nil && line == nil }
    }

    static func settings(from raw: String) -> CueSettings {
        var settings = CueSettings()
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            // Both `line` and `position` may carry a trailing alignment hint
            // (`line:90%,end`). We place from the primary value only.
            let value = pair[1].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]

            switch pair[0] {
            case "align":
                settings.align = String(value).lowercased()
            case "position":
                settings.position = percentage(value)
            case "line":
                if let percent = percentage(value) {
                    settings.line = .percent(percent)
                } else if let number = Int(value) {
                    settings.line = .number(number)
                }
            default:
                // vertical / size / region are not mapped; ASS has no equivalent
                // that would survive the style override.
                continue
            }
        }
        return settings
    }

    private static func percentage(_ value: some StringProtocol) -> Double? {
        guard value.hasSuffix("%"), let parsed = Double(value.dropLast()), parsed.isFinite else { return nil }
        return parsed
    }

    /// The ASS override block that reproduces these settings, or nil to leave the
    /// cue in the default bottom-centre flow.
    ///
    /// Vertical bands are approximate by necessity: WebVTT's `line` is the top
    /// edge of the cue box, while ASS anchors at the corner named by `\an`. We
    /// pick the band from the percentage and anchor there, which is exact for
    /// top placement and off by up to a line height elsewhere. Getting closer
    /// would need the laid-out box height, which does not exist before rendering.
    static func override(for settings: CueSettings) -> String? {
        guard !settings.isEmpty else { return nil }

        let horizontal: Int
        switch settings.align {
        case "start", "left": horizontal = 1
        case "end", "right": horizontal = 3
        default: horizontal = 2
        }

        // 0 = bottom (\an1-3), 1 = middle (\an4-6), 2 = top (\an7-9)
        var band = 0
        var y: Double?
        switch settings.line {
        case .percent(let percent):
            band = percent < 33 ? 2 : (percent < 67 ? 1 : 0)
            y = percent / 100 * Double(ASSScriptBuilder.playResY)
        case .number(let number):
            band = number < 0 ? 0 : 2
        case nil:
            band = 0
        }

        var block = "{\\an\(horizontal + band * 3)"

        if settings.position != nil || y != nil {
            let x = settings.position.map { $0 / 100 * Double(ASSScriptBuilder.playResX) }
                ?? defaultX(forHorizontal: horizontal)
            block += "\\pos(\(Int(x.rounded())),\(Int((y ?? defaultY(forBand: band)).rounded())))"
        }

        return block + "}"
    }

    private static func defaultX(forHorizontal horizontal: Int) -> Double {
        switch horizontal {
        case 1: Double(ASSScriptBuilder.marginHorizontal)
        case 3: Double(ASSScriptBuilder.playResX - ASSScriptBuilder.marginHorizontal)
        default: Double(ASSScriptBuilder.playResX) / 2
        }
    }

    private static func defaultY(forBand band: Int) -> Double {
        switch band {
        case 2: Double(ASSScriptBuilder.marginVertical)
        case 1: Double(ASSScriptBuilder.playResY) / 2
        default: Double(ASSScriptBuilder.playResY - ASSScriptBuilder.marginVertical)
        }
    }

    // MARK: - Parsing

    private static let blockKeywords = ["NOTE", "STYLE", "REGION"]

    static func events(from source: String) -> [ASSEvent] {
        let text = CueMarkup.normalized(source)
        var events: [ASSEvent] = []

        // Block-at-a-time, because NOTE/STYLE/REGION are defined by the blank
        // line that ends them.
        for rawBlock in text.components(separatedBy: "\n\n") {
            let lines = rawBlock
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            guard let first = lines.first else { continue }

            // NOTE/STYLE/REGION are checked by keyword because their bodies can
            // contain anything, including an arrow.
            if blockKeywords.contains(where: { first == $0 || first.hasPrefix($0 + " ") }) { continue }

            guard let timingIndex = lines.firstIndex(where: { CueMarkup.timing(fromLine: $0) != nil }),
                  let timing = CueMarkup.timing(fromLine: lines[timingIndex]) else {
                continue
            }

            // Anything above the timing line is the optional cue identifier, or —
            // in the first block — the WEBVTT signature and its headers. That
            // includes X-TIMESTAMP-MAP, whose MPEGTS offset must not be applied:
            // Jellyfin's cue times are already absolute.
            let body = lines[lines.index(after: timingIndex)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            let tokens = CueMarkup.tokenize(body, options: .init(decodesEntities: true))
            let placement = override(for: settings(from: timing.settings)) ?? ""
            events.append(
                ASSEvent(start: timing.start, end: timing.end, text: placement + CueMarkup.assText(tokens))
            )
        }

        return events
    }

    static func script(from source: String, fontFamily: String) -> String {
        ASSScriptBuilder.script(events: events(from: source), fontFamily: fontFamily)
    }
}
