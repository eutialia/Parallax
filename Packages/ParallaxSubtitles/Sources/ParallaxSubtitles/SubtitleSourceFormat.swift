/// The format of the bytes handed to `SubtitleRenderer.load(_:format:)`.
///
/// Everything is rendered as ASS. `.srt` and `.vtt` are converted to a
/// synthesized ASS script first, so a single engine and a single style override
/// cover every source.
public enum SubtitleSourceFormat: Sendable, CaseIterable {
    case ass
    case ssa
    case srt
    case vtt

    /// Whether the bytes have to go through a converter before libass sees them —
    /// and therefore whether the resulting script is OURS. A converted source
    /// carries no styling of its own, so the user's settings own every field of
    /// it; an authored one arrives with a creator's typesetting and keeps it.
    public var needsConversion: Bool {
        switch self {
        case .ass, .ssa: false
        case .srt, .vtt: true
        }
    }
}

public enum SubtitleError: Error, Sendable, Equatable {
    /// libass could not be initialised — the engine is unusable for this session.
    case engineUnavailable
    /// A converted sidecar was not valid UTF-8. Legacy single-byte encodings land here.
    case undecodableText
    /// The source parsed, but carried no displayable cue.
    case noCues
}
