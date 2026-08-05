import Foundation

/// One `Dialogue:` line waiting to be written out.
struct ASSEvent: Equatable, Sendable {
    /// Seconds.
    var start: Double
    /// Seconds.
    var end: Double
    /// Already escaped and tagged; goes into the Text field verbatim.
    var text: String
}

/// Turns converted cues into a complete ASS script.
///
/// Everything that is not ASS to begin with (SRT, WebVTT) becomes an ASS script
/// before it reaches libass — the same "one format internally" approach mpv
/// takes. That keeps a single rendering path and lets the style override apply
/// uniformly no matter what the sidecar was.
enum ASSScriptBuilder {

    /// Synthesized scripts are authored against a 1280x720 canvas.
    ///
    /// The number itself does not matter to the output — libass scales PlayRes
    /// to the render frame — but it has to be *some* fixed choice so that cue
    /// positions converted from WebVTT percentages land where they should. 720p
    /// keeps the arithmetic readable (1% = 12.8 x 7.2 px) and matches the
    /// resolution most modern ASS files are authored at.
    static let playResX = 1280
    static let playResY = 720

    /// Font size and margins for the synthesized Default style, in PlayRes units.
    /// 48/720 puts the text at 6.7% of the picture height, the usual range for
    /// broadcast subtitles.
    static let fontSize = 48
    static let marginHorizontal = 40
    static let marginVertical = 36

    /// Border geometry, shared with the style override so the two cannot drift.
    /// 2.4/48 = 5% of the font size, the proportion VSFilter-era scripts use.
    /// At `BorderStyle = 3` the same number becomes the opaque box's padding.
    static let outlineWidth = 2.4
    static let shadowOffset = 1.2

    /// `H:MM:SS.cc` — ASS stores centiseconds, so sub-10ms detail is lost by design.
    static func timecode(_ seconds: Double) -> String {
        let clamped = min(max(0, seconds), 359_999.99)
        let total = Int((clamped * 100).rounded())
        let centiseconds = total % 100
        let totalSeconds = total / 100
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%d:%02d:%02d.%02d", h, m, s, centiseconds)
    }

    static func script(events: [ASSEvent], fontFamily: String) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(playResX)
        PlayResY: \(playResY)
        WrapStyle: 0
        ScaledBorderAndShadow: yes
        YCbCr Matrix: None

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(styleSafe(fontFamily)),\(fontSize),&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,\(outlineWidth),\(shadowOffset),2,\(marginHorizontal),\(marginHorizontal),\(marginVertical),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """

        for event in events.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            out += "Dialogue: 0,\(timecode(event.start)),\(timecode(event.end)),Default,,0,0,0,,\(event.text)\n"
        }
        return out
    }

    /// Style fields are comma separated, so a comma in a font name would shift
    /// every later field.
    private static func styleSafe(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Helvetica Neue" : cleaned
    }
}
