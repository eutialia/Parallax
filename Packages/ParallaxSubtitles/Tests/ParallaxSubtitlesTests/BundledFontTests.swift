import Foundation
import Testing

@testable import ParallaxSubtitles

/// The bundle as shipped: which files are there, what nameID 1 each face
/// declares, and whether the routing table's family strings are the ones libass
/// will actually see.
///
/// `\fn` matches nameID 1 and nothing else, and with `ASS_FONTPROVIDER_NONE`
/// there is no second chance — a family string that drifts from the file
/// silently unresolves every run routed to it, and the caption renders through
/// `default_family` in the wrong script. So every name here is READ from the
/// shipped bytes and compared, never assumed.
@Suite("Bundled fonts")
struct BundledFontTests {

    /// nameID 1 of every face of every shipped file. Written out rather than
    /// derived: a derivation would follow the files wherever they drifted.
    static let expectedFamilies: [String: [String]] = [
        "NotoSans-Regular.ttf": ["Noto Sans"],
        "NotoSerif-Regular.ttf": ["Noto Serif"],
        "NotoSansCJK-Regular.ttc": [
            "Noto Sans CJK JP", "Noto Sans CJK KR", "Noto Sans CJK SC",
            "Noto Sans CJK TC", "Noto Sans CJK HK",
            "Noto Sans Mono CJK JP", "Noto Sans Mono CJK KR", "Noto Sans Mono CJK SC",
            "Noto Sans Mono CJK TC", "Noto Sans Mono CJK HK",
        ],
        "NotoSerifCJK-Regular.ttc": [
            "Noto Serif CJK JP", "Noto Serif CJK KR", "Noto Serif CJK SC",
            "Noto Serif CJK TC", "Noto Serif CJK HK",
        ],
        "NotoNaskhArabic-Regular.ttf": ["Noto Naskh Arabic"],
        "NotoSansThai-Regular.ttf": ["Noto Sans Thai"],
        "NotoSerifThai-Regular.ttf": ["Noto Serif Thai"],
        "NotoSansHebrew-Regular.ttf": ["Noto Sans Hebrew"],
        "NotoSerifHebrew-Regular.ttf": ["Noto Serif Hebrew"],
        "NotoSansDevanagari-Regular.ttf": ["Noto Sans Devanagari"],
        "NotoSerifDevanagari-Regular.ttf": ["Noto Serif Devanagari"],
        "NotoSansBengali-Regular.ttf": ["Noto Sans Bengali"],
        "NotoSerifBengali-Regular.ttf": ["Noto Serif Bengali"],
        "NotoSansTamil-Regular.ttf": ["Noto Sans Tamil"],
        "NotoSerifTamil-Regular.ttf": ["Noto Serif Tamil"],
        "NotoSansTelugu-Regular.ttf": ["Noto Sans Telugu"],
        "NotoSerifTelugu-Regular.ttf": ["Noto Serif Telugu"],
        "NotoSansKannada-Regular.ttf": ["Noto Sans Kannada"],
        "NotoSerifKannada-Regular.ttf": ["Noto Serif Kannada"],
        "NotoSansMalayalam-Regular.ttf": ["Noto Sans Malayalam"],
        "NotoSerifMalayalam-Regular.ttf": ["Noto Serif Malayalam"],
        "NotoSansGujarati-Regular.ttf": ["Noto Sans Gujarati"],
        "NotoSerifGujarati-Regular.ttf": ["Noto Serif Gujarati"],
        "NotoSansGurmukhi-Regular.ttf": ["Noto Sans Gurmukhi"],
        "NotoSerifGurmukhi-Regular.ttf": ["Noto Serif Gurmukhi"],
        "NotoSansSinhala-Regular.ttf": ["Noto Sans Sinhala"],
        "NotoSerifSinhala-Regular.ttf": ["Noto Serif Sinhala"],
        "NotoSansKhmer-Regular.ttf": ["Noto Sans Khmer"],
        "NotoSerifKhmer-Regular.ttf": ["Noto Serif Khmer"],
        "NotoSansLao-Regular.ttf": ["Noto Sans Lao"],
        "NotoSerifLao-Regular.ttf": ["Noto Serif Lao"],
        "NotoSansMyanmar-Regular.ttf": ["Noto Sans Myanmar"],
        "NotoSerifMyanmar-Regular.ttf": ["Noto Serif Myanmar"],
        "NotoSansGeorgian-Regular.ttf": ["Noto Sans Georgian"],
        "NotoSerifGeorgian-Regular.ttf": ["Noto Serif Georgian"],
        "NotoSansArmenian-Regular.ttf": ["Noto Sans Armenian"],
        "NotoSerifArmenian-Regular.ttf": ["Noto Serif Armenian"],
        "NotoSansOriya-Regular.ttf": ["Noto Sans Oriya"],
        "NotoSerifOriya-Regular.ttf": ["Noto Serif Oriya"],
    ]

    /// The directory is also handed to VLC as `:ssa-fontsdir`, and libass'
    /// `load_fonts_from_dir` calls `ass_add_font` on EVERY file it finds — so a
    /// stray README or licence text is one warning per launch. Nothing but faces
    /// may live here; the shared OFL text ships in the app's Resources/Licenses.
    @Test("the fonts directory holds exactly the expected files and nothing else")
    func directoryContents() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: SubtitleFontBundle.directoryURL.path
        )
        #expect(Set(contents) == Set(Self.expectedFamilies.keys))
        #expect(SubtitleFontBundle.fileURLs.count == Self.expectedFamilies.count)
        #expect(SubtitleFontBundle.defaultFontPath?.hasSuffix("NotoSans-Regular.ttf") == true)
    }

    @Test("every face declares the family name the bundle claims for it")
    func faceNamesMatchTheFiles() throws {
        for url in SubtitleFontBundle.fileURLs {
            let name = url.lastPathComponent
            let expected = try #require(Self.expectedFamilies[name], "unexpected file \(name)")
            #expect(SFNTFace.faces(of: url).map(\.familyName) == expected, "\(name)")
        }
    }

    @Test("every family the routing table names is a face we actually ship")
    func tableNamesMatchTheFiles() {
        let shipped = Set(Self.expectedFamilies.values.flatMap { $0 })
        for script in SubtitleFontBundle.Script.allCases {
            guard let entry = SubtitleFontBundle.table[script] else {
                Issue.record("no table row for \(script)")
                continue
            }
            #expect(shipped.contains(entry.sans), "\(script) sans \(entry.sans)")
            #expect(shipped.contains(entry.serif), "\(script) serif \(entry.serif)")
            #expect(SubtitleFontBundle.facesByFamily[entry.sans] != nil, "\(entry.sans)")
            #expect(SubtitleFontBundle.facesByFamily[entry.serif] != nil, "\(entry.serif)")
            // A row that names a file it does not ship would register nothing.
            #expect(entry.fileURLs.count == entry.fileNames.count, "\(script) files")
        }
    }

    @Test("the Latin faces are the style fonts, and CJK names carry their region")
    func styleAndRegionNaming() {
        #expect(SubtitleFontBundle.sansFamily == "Noto Sans")
        #expect(SubtitleFontBundle.serifFamily == "Noto Serif")
        #expect(SubtitleFontBundle.family(design: .sans, script: .common) == "Noto Sans")
        #expect(SubtitleFontBundle.family(design: .serif, script: .common) == "Noto Serif")

        #expect(SubtitleFontBundle.family(design: .sans, language: .japanese) == "Noto Sans CJK JP")
        #expect(SubtitleFontBundle.family(design: .sans, language: .korean) == "Noto Sans CJK KR")
        #expect(SubtitleFontBundle.family(design: .sans, language: .simplifiedChinese)
            == "Noto Sans CJK SC")
        #expect(SubtitleFontBundle.family(design: .sans, language: .traditionalChinese)
            == "Noto Sans CJK TC")
        #expect(SubtitleFontBundle.family(design: .serif, language: .simplifiedChinese)
            == "Noto Serif CJK SC")
        // No CJK language is NOT "Japanese" here: Noto keeps Latin and CJK in
        // separate files, so a track with no CJK must name the Latin face.
        #expect(SubtitleFontBundle.family(design: .sans, language: nil) == "Noto Sans")
        #expect(SubtitleFontBundle.family(design: .serif, language: nil) == "Noto Serif")
    }

    @Test("Arabic is served by the Naskh face in both designs")
    func arabicServesBothDesigns() {
        #expect(SubtitleFontBundle.family(design: .sans, script: .arabic) == "Noto Naskh Arabic")
        #expect(SubtitleFontBundle.family(design: .serif, script: .arabic) == "Noto Naskh Arabic")
    }

    @Test("a family name maps back to its design")
    func designRouting() {
        #expect(SubtitleFontBundle.design(forFamily: "Noto Sans CJK TC") == .sans)
        #expect(SubtitleFontBundle.design(forFamily: "Noto Serif") == .serif)
        #expect(SubtitleFontBundle.design(forFamily: "Noto Serif Thai") == .serif)
        // Unknown names are served by Sans — libass resolves them through
        // default_family regardless.
        #expect(SubtitleFontBundle.design(forFamily: "Arial") == .sans)
    }

    // MARK: - Coverage

    /// One line per script the bundle exists to serve. If any scalar here has no
    /// glyph anywhere in the bundle, a real subtitle in that language renders as
    /// tofu — there is no system fallback to hide it.
    static let probes: [(name: String, text: String)] = [
        ("Turkish", "İıŞşĞğÇçÖöÜü"),
        ("Polish", "Łódź ąęśż"),
        ("Vietnamese", "Việt Nam ở đây"),
        ("Greek", "Ελληνικά ά"),
        ("Cyrillic", "Привет"),
        ("Thai", "สวัสดี"),
        ("Arabic", "مرحبا"),
        ("Hebrew", "שלום"),
        ("Hindi", "नमस्ते"),
        ("Bengali", "নমস্কার"),
        ("Tamil", "வணக்கம்"),
        ("Telugu", "నమస్కారం"),
        ("Khmer", "សួស្តី"),
        ("Georgian", "გამარჯობა"),
        ("Armenian", "Բարև"),
        ("Oriya", "ନମସ୍କାର"),
        ("CJK", "简体 繁體 日本語 한국어"),
        // Symbols a real subtitle carries and the Latin faces do NOT: the
        // music notes of a song cue, the arrows and bullets of a sign, the
        // guillemets of European dialogue. Routed by cmap coverage, so a face
        // losing them is caught here rather than on screen.
        ("Symbols", "♪ ♫ ♥ ★ → ● ▶ « »"),
    ]

    /// Whether ANY shipped face can draw the scalar, read from our own files'
    /// `cmap`s. Deliberately not CoreText: iOS ships several Noto faces of its
    /// own, so a CoreText query could answer "yes" from a system font and leave
    /// a hole in the bundle invisible.
    static func bundleCovers(_ scalar: UInt32) -> Bool {
        SubtitleFontBundle.facesByFamily.values.contains { $0.coverage.contains(scalar) }
    }

    @Test("every probe scalar has a glyph somewhere in the bundle", arguments: BundledFontTests.probes)
    func bundleCoversEveryProbe(probe: (name: String, text: String)) {
        for scalar in probe.text.unicodeScalars {
            #expect(
                Self.bundleCovers(scalar.value),
                "\(probe.name): U+\(String(scalar.value, radix: 16, uppercase: true)) uncovered"
            )
        }
    }

    /// The stronger claim, and the one that actually keeps tofu off the screen:
    /// the face ROUTING picks for a run has the glyphs of that run. "Somewhere
    /// in the bundle" is worth nothing if the tagger names a different file.
    @Test("the face routing picks for a run covers that run", arguments: BundledFontTests.probes)
    func routedFaceCoversItsRun(probe: (name: String, text: String)) throws {
        for design in SubtitleFontBundle.Design.allCases {
            let plan = SubtitleFontPlan.build(
                lines: [probe.text],
                styleFamily: SubtitleFontBundle.family(design: design, script: .common),
                languageHint: nil
            )
            for (runClass, run) in scriptRuns(of: probe.text, routing: plan.symbolRouting) {
                let family = plan.family(forRun: runClass, line: probe.text)
                    ?? plan.styleFamily
                let coverage = try #require(
                    SubtitleFontBundle.facesByFamily[family]?.coverage, "\(family)"
                )
                for scalar in run.unicodeScalars {
                    #expect(
                        coverage.contains(scalar.value),
                        """
                        \(probe.name)/\(design): \(family) lacks \
                        U+\(String(scalar.value, radix: 16, uppercase: true))
                        """
                    )
                }
            }
        }
    }
}

/// Splits text the way the tagger does — same classifier, same neutral carry —
/// so a coverage assertion is made against the runs that will really be tagged.
func scriptRuns(
    of text: String, routing: SubtitleScript.SymbolRouting = .none
) -> [(SubtitleScript.Class, String)] {
    var runs: [(SubtitleScript.Class, String)] = []
    var current: SubtitleScript.Class = .common
    for character in text {
        let resolved = SubtitleScript.classify(character, routing: routing) ?? current
        if resolved != current || runs.isEmpty {
            runs.append((resolved, ""))
            current = resolved
        }
        runs[runs.count - 1].1.append(character)
    }
    return runs
}
