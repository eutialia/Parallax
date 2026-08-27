/// Who owns a track's look: us, or the person who authored it.
///
/// SRT and WebVTT carry no styling of their own — we synthesize the whole ASS
/// script, so every field is ours and the user's settings always apply. ASS/SSA
/// arrives with a creator's palette, typefaces and placement; those survive
/// untouched unless the user explicitly opts into overriding them, and even then
/// PLACEMENT is never taken (see `.margins`).
public enum SubtitleStylePolicy: Sendable, Equatable {
    /// Apply the user's style wholesale — we authored these cues.
    case userStyle
    /// Keep the creator's styling except for `overrides`. An empty set means
    /// "render exactly as authored".
    case authored(overrides: Set<Field>)

    /// The groups a style override can replace, matching libass' selective
    /// override bits: one flag per group, so a group is all-or-nothing.
    public enum Field: Sendable, Hashable, CaseIterable {
        case font
        case size
        case color
        case border
        case margins
    }

    /// Whether the cues came with a creator's styling — true regardless of how
    /// much of it the user chose to override.
    public var isAuthored: Bool {
        if case .authored = self { true } else { false }
    }

    /// The fields an authored track yields when the user asks for their own style.
    /// `.margins` is deliberately absent: a fansub's `\pos` signs and per-speaker
    /// placement are typeset against the picture, and moving them breaks the sign
    /// rather than restyling it.
    public static let authoredOptIn: Set<Field> = [.font, .size, .color, .border]
}

public extension SubtitleSourceFormat {
    /// The style policy for this source, given the user's "Use My Style" toggle.
    func policy(userOverridesAuthored: Bool) -> SubtitleStylePolicy {
        switch self {
        case .srt, .vtt:
            .userStyle
        case .ass, .ssa:
            .authored(overrides: userOverridesAuthored ? SubtitleStylePolicy.authoredOptIn : [])
        }
    }
}

public extension SubtitleStyleOverride {
    /// This override with every group outside `fields` cleared, so a policy that
    /// only yields colour can't smuggle a font or a margin through.
    ///
    /// `shadowAlpha` rides with `.border`: libass reads it through the same
    /// BorderStyle/Outline/Shadow flag, and it is meaningless without one.
    func filtered(to fields: Set<SubtitleStylePolicy.Field>) -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontFamily: fields.contains(.font) ? fontFamily : nil,
            fontScale: fields.contains(.size) ? fontScale : nil,
            primaryColor: fields.contains(.color) ? primaryColor : nil,
            outlineColor: fields.contains(.color) ? outlineColor : nil,
            opaqueBox: fields.contains(.border) ? opaqueBox : nil,
            emHeightRatio: fields.contains(.border) ? emHeightRatio : nil,
            outlineEmRatio: fields.contains(.border) ? outlineEmRatio : nil,
            shadowEmRatio: fields.contains(.border) ? shadowEmRatio : nil,
            shadowAlpha: fields.contains(.border) ? shadowAlpha : nil,
            marginVertical: fields.contains(.margins) ? marginVertical : nil,
            marginHorizontal: fields.contains(.margins) ? marginHorizontal : nil
        )
    }
}
