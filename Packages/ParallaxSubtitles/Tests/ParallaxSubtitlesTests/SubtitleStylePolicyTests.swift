import Testing
@testable import ParallaxSubtitles

/// The (A)(B) contract, as a type: converted formats always take the user's style;
/// authored ones keep their creator's, and yield only the four non-placement groups
/// when the user explicitly opts in.
@Suite("Subtitle style policy")
struct SubtitleStylePolicyTests {

    private static let converted: [SubtitleSourceFormat] = [.srt, .vtt]
    private static let authored: [SubtitleSourceFormat] = [.ass, .ssa]

    @Test("converted formats take the user style, toggle or not",
          arguments: converted, [false, true])
    func convertedAlwaysUserStyle(format: SubtitleSourceFormat, toggle: Bool) {
        #expect(format.policy(userOverridesAuthored: toggle) == .userStyle)
    }

    @Test("authored formats keep their creator's styling with the toggle off",
          arguments: authored)
    func authoredUntouchedByDefault(format: SubtitleSourceFormat) {
        #expect(format.policy(userOverridesAuthored: false) == .authored(overrides: []))
    }

    @Test("authored formats yield font, size, colour and border under the opt-in",
          arguments: authored)
    func authoredOptInYieldsFourGroups(format: SubtitleSourceFormat) {
        #expect(format.policy(userOverridesAuthored: true)
                == .authored(overrides: [.font, .size, .color, .border]))
    }

    /// Placement is the creator's, always: a fansub's `\pos` signs are typeset
    /// against the picture, and moving them breaks the sign rather than restyling it.
    @Test("the opt-in never takes margins", arguments: authored)
    func optInNeverTakesMargins(format: SubtitleSourceFormat) {
        guard case .authored(let fields) = format.policy(userOverridesAuthored: true) else {
            Issue.record("expected an authored policy for \(format)")
            return
        }
        #expect(!fields.contains(.margins))
    }

    @Test("every format resolves to exactly one policy shape",
          arguments: SubtitleSourceFormat.allCases, [false, true])
    func isAuthoredMatchesTheFormat(format: SubtitleSourceFormat, toggle: Bool) {
        let expectedAuthored = format == .ass || format == .ssa
        #expect(format.policy(userOverridesAuthored: toggle).isAuthored == expectedAuthored)
    }
}

@Suite("Subtitle style override filtering")
struct SubtitleStyleOverrideFilterTests {

    /// Every group populated, so a filter that leaks shows up as a non-nil field.
    private static let full = SubtitleStyleOverride(
        fontFamily: "Noto Serif",
        fontScale: 1.5,
        primaryColor: SubtitleColor(red: 1, green: 1, blue: 0),
        outlineColor: SubtitleColor(red: 0, green: 0, blue: 0),
        opaqueBox: true,
        emHeightRatio: 48.0 / 720,
        outlineEmRatio: 0.06,
        shadowEmRatio: 0.04,
        shadowAlpha: 0.55,
        marginVertical: 40,
        marginHorizontal: 44
    )

    @Test("an empty field set clears everything")
    func emptySetIsANoOp() {
        let filtered = Self.full.filtered(to: [])
        #expect(filtered == SubtitleStyleOverride())
        #expect(filtered.overrideBits == 0)
    }

    @Test("the full field set is the identity")
    func fullSetKeepsEverything() {
        #expect(Self.full.filtered(to: Set(SubtitleStylePolicy.Field.allCases)) == Self.full)
    }

    /// One case per group: the group's own fields survive and nothing else does.
    @Test("each group passes only its own fields", arguments: SubtitleStylePolicy.Field.allCases)
    func groupsAreIsolated(field: SubtitleStylePolicy.Field) {
        let only = Self.full.filtered(to: [field])
        #expect((only.fontFamily != nil) == (field == .font))
        #expect((only.fontScale != nil) == (field == .size))
        #expect((only.primaryColor != nil) == (field == .color))
        #expect((only.outlineColor != nil) == (field == .color))
        #expect((only.opaqueBox != nil) == (field == .border))
        #expect((only.emHeightRatio != nil) == (field == .border))
        #expect((only.outlineEmRatio != nil) == (field == .border))
        #expect((only.shadowEmRatio != nil) == (field == .border))
        #expect((only.shadowAlpha != nil) == (field == .border))
        #expect((only.marginVertical != nil) == (field == .margins))
        #expect((only.marginHorizontal != nil) == (field == .margins))
    }

    /// The authored opt-in must not set libass' MARGINS bit — that is what would
    /// move the creator's positioned signs.
    @Test("the authored opt-in leaves the margins bit unset")
    func authoredOptInSetsNoMarginBit() {
        let filtered = Self.full.filtered(to: SubtitleStylePolicy.authoredOptIn)
        #expect(!filtered.overridesMargins)
        #expect(filtered.overridesBorder)
        #expect(filtered.overridesColors)
        #expect(filtered.fontFamily == "Noto Serif")
        #expect(filtered.fontScale == 1.5)
    }
}
