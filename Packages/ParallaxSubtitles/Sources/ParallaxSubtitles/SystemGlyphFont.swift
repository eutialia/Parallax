import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage

/// Rebuilds system glyphs into a FreeType-readable font, on device, at track load.
///
/// Apple has been migrating its CJK fonts (PingFang first) to a proprietary
/// outline table (`hvgl`) with no `glyf`/`CFF` — CoreText renders it, FreeType
/// cannot open it, and FreeType is what libass rasterizes with. The OS clearly
/// *can* draw those glyphs, so this type asks CoreText for the outlines of
/// exactly the characters a subtitle track uses (`CTFontCreatePathForGlyph`
/// decodes hvgl into plain quadratic paths) and assembles them into a minimal
/// TrueType subset registered with libass under the same family name. The
/// glyphs on screen are the system font's own; nothing is bundled or
/// redistributed, and the subset lives only in memory for the track's lifetime.
///
/// Font choice is planned per LANGUAGE, not per character. CoreText's cascade
/// for a lone Han character follows the device's preferred-languages list, so
/// character-at-a-time resolution splits one Chinese line between a Japanese
/// font (for characters Japanese also uses) and PingFang (for the rest) — two
/// designs and two libass size normalizations in a single run. `plan(lines:)`
/// decides the track's default script first, classifies each line, and
/// resolves every character of a line with the language attached, so a line
/// renders from one coherent family.
enum SystemGlyphFont {

    // MARK: - Scripts and scalar classes

    /// The CJK languages whose writing systems need distinct font choices.
    /// Raw values are the BCP-47 tags CoreText's language-aware cascade takes.
    enum Language: String, CaseIterable, Sendable {
        case japanese = "ja"
        case korean = "ko"
        case simplifiedChinese = "zh-Hans"
        case traditionalChinese = "zh-Hant"

        /// Maps a track's language label ("ja", "zh-Hant", "chi-TW", …) onto a
        /// member, comparing whole subtags (so "zh-Mong" cannot match "mo").
        /// Bare "zh" carries no script and maps to nothing — content detection
        /// decides instead.
        init?(hintTag: String?) {
            guard let tag = hintTag?.lowercased(), !tag.isEmpty else { return nil }
            let subtags = tag.split { $0 == "-" || $0 == "_" }.map(String.init)
            guard let primary = subtags.first else { return nil }
            switch primary {
            case "ja", "jpn": self = .japanese
            case "ko", "kor": self = .korean
            case "zh", "chi", "zho", "cmn", "yue":
                let rest = subtags.dropFirst()
                if rest.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) {
                    self = .traditionalChinese
                } else if rest.contains(where: { ["hans", "cn", "sg"].contains($0) }) {
                    self = .simplifiedChinese
                } else {
                    return nil
                }
            default: return nil
            }
        }

        var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
    }

    /// Scalars that belong to a CJK font's design: ideographs, kana, hangul
    /// syllables, CJK punctuation/radicals, compatibility and full/half-width
    /// forms. Deliberately NOT "everything ≥ U+2E80": emoji, symbols and
    /// private-use scalars must stay with their own system fonts — pulling
    /// them into a subset yields empty outlines (color fonts have no paths)
    /// that render as blanks.
    static func isCJKScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x9FFF,       // radicals … punctuation, kana, unified + ext A
             0xAC00...0xD7A3,       // hangul syllables
             0xF900...0xFAFF,       // compatibility ideographs
             0xFE30...0xFE4F,       // vertical/compat forms
             0xFF00...0xFFEF,       // full-width and half-width forms
             0x20000...0x3FFFF:     // ext B+ and compatibility supplement
            return true
        default:
            return false
        }
    }

    /// Kana that DECIDES a line is Japanese. Excludes the interpunct (・), the
    /// prolonged-sound mark (ー), `゠` and their half-width forms — Chinese
    /// subtitles use them in transliterated names, and one must not flip a
    /// whole line to a Japanese font.
    private static func isDecisiveKana(_ value: UInt32) -> Bool {
        switch value {
        case 0x3041...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF,
             0x31F0...0x31FF, 0xFF66...0xFF6F, 0xFF71...0xFF9D:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3: return true
        default: return false
        }
    }

    private static func isHan(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }

    // MARK: - Language decisions

    /// The script assumed for lines that carry no decisive evidence of their
    /// own. The track's label wins outright — a Japanese track's kanji-only
    /// lines must NOT be second-guessed (the recognizer only knows the two
    /// Chinese classes, so it scores 東京駅 as high-confidence zh-Hant).
    /// Without a label: meaningful kana/hangul presence claims the track, and
    /// otherwise the Han-only lines vote Hans vs Hant.
    static func trackDefaultLanguage(lines: [String], hint: String?) -> Language {
        if let hinted = Language(hintTag: hint) { return hinted }

        var kanaLines = 0
        var hangulLines = 0
        var hanOnlyLines: [String] = []
        for line in lines {
            var sawHan = false
            var decided = false
            scan: for scalar in line.unicodeScalars {
                if isDecisiveKana(scalar.value) { kanaLines += 1; decided = true; break scan }
                if isHangul(scalar.value) { hangulLines += 1; decided = true; break scan }
                if isHan(scalar.value) { sawHan = true }
            }
            if !decided, sawHan { hanOnlyLines.append(line) }
        }
        // ≥20% decisive lines is a real second language, not a stray lyric.
        // Dual-language tracks land here too — their Chinese rows escape the
        // Japanese default per line through the font-coverage check in `plan`.
        if kanaLines > 0, kanaLines * 4 >= hanOnlyLines.count { return .japanese }
        if hangulLines > 0, hangulLines * 4 >= hanOnlyLines.count { return .korean }

        var hans = 0
        var hant = 0
        for line in hanOnlyLines.prefix(chineseVoteSampleLimit) {
            switch chineseScript(of: line) {
            case .simplifiedChinese: hans += 1
            case .traditionalChinese: hant += 1
            default: break
            }
        }
        if hans != hant { return hans > hant ? .simplifiedChinese : .traditionalChinese }
        return chineseScript(of: hanOnlyLines.prefix(chineseVoteSampleLimit).joined(separator: "\n"))
            ?? .simplifiedChinese
    }

    /// Whole-track voting caps here — enough for any real ambiguity, and it
    /// keeps recognizer cost bounded on multi-thousand-cue tracks.
    private static let chineseVoteSampleLimit = 400

    /// The language governing font choice for one visual line, or nil when the
    /// line has no CJK content at all. Kana and hangul decide outright; Han is
    /// discriminated Hans/Hant only inside a Chinese-defaulted track; anything
    /// else (shared characters, CJK punctuation alone) takes the track default.
    static func language(of line: String, trackDefault: Language) -> Language? {
        var sawCJK = false
        var sawHan = false
        for scalar in line.unicodeScalars {
            if isDecisiveKana(scalar.value) { return .japanese }
            if isHangul(scalar.value) { return .korean }
            if isHan(scalar.value) {
                sawCJK = true
                sawHan = true
            } else if isCJKScalar(scalar.value) {
                sawCJK = true
            }
        }
        guard sawCJK else { return nil }
        if sawHan, trackDefault.isChinese, let script = chineseScript(of: line) { return script }
        return trackDefault
    }

    /// zh-Hans vs zh-Hant for Han text, or nil when the characters don't tip
    /// the scales either way. Only meaningful for text already known to be
    /// Chinese: the recognizer is constrained to the two Chinese classes and
    /// renormalizes over them, so it is confidently wrong about Japanese kanji.
    static func chineseScript(of text: String) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2)
            .max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }),
            best.value >= 0.65 else { return nil }
        switch best.key {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        default: return nil
        }
    }

    // MARK: - Track plan

    /// One synthesized subset: the family name libass should index it under and
    /// the TrueType blob.
    struct Subset {
        let familyName: String
        let data: Data
    }

    /// Everything a track needs for deterministic CJK font choice: the memory
    /// fonts to register, and the family name serving each language (synthesized
    /// or a real readable file — either way the name converted cues get tagged
    /// with, so libass matches by family and never consults its per-glyph
    /// fallback for CJK).
    struct Plan {
        var subsets: [Subset]
        let familyByLanguage: [Language: String]
        /// winAscent+winDescent over unitsPerEm, per planned family. libass
        /// sizes fonts VSFilter-style by dividing by this box, so a CJK face
        /// declaring 1.36 em renders at 73% of the style size next to Latin.
        /// Converted cues neutralize the DIFFERENCE against the style font
        /// with `\fs`, so every family in a cue agrees on em size.
        let sizeFactorByFamily: [String: Double]
        /// The style font's own box — the reference the per-run compensation is
        /// relative to (the app-side scale mapping already accounts for it).
        let styleFontEmBoxFactor: Double
        let trackDefaultLanguage: Language
        /// Per-line classification computed once at plan time — detection runs
        /// a recognizer, and tagging revisits every line.
        let languageByLine: [String: Language]
        /// Source for shadow subsets (authored scripts naming unusable fonts):
        /// the default language's resolved font and every CJK scalar the track
        /// uses, so one shadow covers a whole missing-font style.
        let shadowFont: CTFont
        let shadowScalars: [Unicode.Scalar]

        func family(forLine line: String) -> String? {
            let language = languageByLine[line]
                ?? SystemGlyphFont.language(of: line, trackDefault: trackDefaultLanguage)
            return language.flatMap { familyByLanguage[$0] }
        }

        func sizeFactor(forFamily family: String) -> Double {
            sizeFactorByFamily[family] ?? 1
        }
    }

    /// Builds the font plan for a track's visual lines. Nil when the track has
    /// no CJK content — the common case, and it must cost nearly nothing.
    static func plan(lines: [String], baseFamily: String, languageHint: String?) -> Plan? {
        let hasCJK = lines.contains { $0.unicodeScalars.contains { isCJKScalar($0.value) } }
        guard hasCJK else { return nil }

        let trackDefault = trackDefaultLanguage(lines: lines, hint: languageHint)

        // A ja/ko default still hosts Chinese rows in dual-language tracks. The
        // discriminator is the language's own character SET, not statistics: a
        // Han line using characters the default language's font doesn't carry
        // (simplified forms are absent from Japanese fonts) is Chinese.
        let defaultFontProbe: CTFont? = trackDefault.isChinese ? nil : CTFontCreateForStringWithLanguage(
            CTFontCreateWithName(baseFamily as CFString, synthesisPointSize, nil),
            "永" as CFString, CFRange(location: 0, length: 1),
            trackDefault.rawValue as CFString
        )
        func classify(_ line: String) -> Language? {
            guard let language = language(of: line, trackDefault: trackDefault) else { return nil }
            guard language == trackDefault, !trackDefault.isChinese, let defaultFontProbe,
                  line.unicodeScalars.contains(where: { isHan($0.value) })
            else { return language }
            let hanScalars = line.unicodeScalars.filter { isHan($0.value) }
            var chars = hanScalars.flatMap { String(String.UnicodeScalarView([$0])).utf16 }
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let covered = CTFontGetGlyphsForCharacters(defaultFontProbe, &chars, &glyphs, chars.count)
            guard !covered else { return language }
            return chineseScript(of: line) ?? .simplifiedChinese
        }

        var languageByLine: [String: Language] = [:]
        var scalarsByLanguage: [Language: Set<Unicode.Scalar>] = [:]
        for line in lines where languageByLine[line] == nil {
            guard let language = classify(line) else { continue }
            languageByLine[line] = language
            for scalar in line.unicodeScalars where isCJKScalar(scalar.value) {
                scalarsByLanguage[language, default: []].insert(scalar)
            }
        }
        guard !scalarsByLanguage.isEmpty else { return nil }

        let base = CTFontCreateWithName(baseFamily as CFString, synthesisPointSize, nil)
        var familyGroups: [String: (font: CTFont, url: URL?, scalars: Set<Unicode.Scalar>)] = [:]
        var familyByLanguage: [Language: String] = [:]
        for (language, scalars) in scalarsByLanguage {
            var countByFamily: [String: Int] = [:]
            for scalar in scalars {
                let string = String(String.UnicodeScalarView([scalar]))
                let resolved = CTFontCreateForStringWithLanguage(
                    base, string as CFString,
                    CFRange(location: 0, length: string.utf16.count),
                    language.rawValue as CFString
                )
                let family = CTFontCopyFamilyName(resolved) as String
                if familyGroups[family] == nil {
                    let url = CTFontCopyAttribute(resolved, kCTFontURLAttribute) as? URL
                    familyGroups[family] = (resolved, url, [])
                }
                familyGroups[family]?.scalars.insert(scalar)
                countByFamily[family, default: 0] += 1
            }
            // Most characters resolve to one family; stragglers (rare symbols)
            // still get subsets below, reached through libass' fallback.
            familyByLanguage[language] = countByFamily
                .max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
        }

        // A file FreeType can open needs no help. A font with no file URL at
        // all (registered in-memory by the system) can only be reached here.
        let subsets: [Subset] = familyGroups
            .filter { _, group in
                if let url = group.url, fileIsFreeTypeReadable(url) { return false }
                return true
            }
            .sorted { $0.key < $1.key }
            .compactMap { family, group in
                subsetFont(scalars: Array(group.scalars), from: group.font)
                    .map { Subset(familyName: family, data: $0) }
            }

        var sizeFactorByFamily: [String: Double] = [:]
        for family in Set(familyByLanguage.values) {
            guard let url = familyGroups[family]?.url,
                  let metrics = faceMetrics(of: url),
                  metrics.unitsPerEm > 0 else { continue }
            let winBox = Double(metrics.winAscent) + Double(metrics.winDescent)
            guard winBox > 0 else { continue }
            sizeFactorByFamily[family] = winBox / Double(metrics.unitsPerEm)
        }

        let shadowFont = familyByLanguage[trackDefault].flatMap { familyGroups[$0]?.font }
            ?? familyGroups.min { $0.key < $1.key }?.value.font
            ?? base
        let allScalars = scalarsByLanguage.values.reduce(into: Set<Unicode.Scalar>()) {
            $0.formUnion($1)
        }
        return Plan(
            subsets: subsets,
            familyByLanguage: familyByLanguage,
            sizeFactorByFamily: sizeFactorByFamily,
            styleFontEmBoxFactor: SubtitleFontMetrics.emBoxFactor(forFamily: baseFamily),
            trackDefaultLanguage: trackDefault,
            languageByLine: languageByLine,
            shadowFont: shadowFont,
            shadowScalars: Array(allScalars)
        )
    }

    // MARK: - Shadow subsets

    /// A font family an authored script requests together with the source its
    /// stand-in glyphs come from.
    struct ShadowRequest {
        let name: String
        let font: CTFont
    }

    /// Subsets registered under family names an authored script requests but
    /// libass cannot serve from disk. libass then satisfies the style by direct
    /// family match — the whole style renders from one coherent font instead of
    /// a per-glyph fallback lottery. Outlines are extracted once per distinct
    /// source font and reassembled per name; a rebuilt name table is cheap, a
    /// re-extraction of a few thousand outlines is not.
    static func shadowSubsets(
        requests: [ShadowRequest],
        scalars: [Unicode.Scalar]
    ) -> [Subset] {
        var extracted: [ObjectIdentifier: ExtractedFont?] = [:]
        return requests
            .sorted { $0.name < $1.name }
            .compactMap { request in
                let key = ObjectIdentifier(request.font)
                let source = extracted[key] ?? extractFont(scalars: scalars, from: request.font)
                extracted[key] = source
                return source.map {
                    Subset(familyName: request.name, data: assemble($0, familyName: request.name))
                }
            }
    }

    /// A font CoreText resolves for `name` that libass cannot use from disk:
    /// either nothing real is installed under that name, or the installed face
    /// is FreeType-unreadable (an hvgl family named directly by a script, e.g.
    /// `Style: …,PingFang SC,…`). Nil when libass can serve the name itself.
    static func unusableRequestedFont(named name: String) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, synthesisPointSize, nil)
        let candidates = [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyPostScriptName(font) as String,
            CTFontCopyFullName(font) as String,
        ]
        let installed = candidates.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard installed else { return nil }  // missing → shadow from the plan's font
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              fileIsFreeTypeReadable(url)
        else { return font }  // installed, but libass can't read it → shadow from itself
        return nil
    }

    /// Whether CoreText resolves `name` to an actual installed face (as opposed
    /// to silently substituting one), under any of its addressable names.
    static func fontFamilyInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let candidates = [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyPostScriptName(font) as String,
            CTFontCopyFullName(font) as String,
        ]
        return candidates.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - File readability

    /// FreeType reads a face iff its outlines live in `glyf`(+`loca`) or
    /// `CFF `/`CFF2`. Checked by parsing the sfnt table directory directly —
    /// deterministic, no FreeType round trip, and honest about future Apple
    /// format migrations (a font that drops these tables fails this check the
    /// day it ships).
    static func fileIsFreeTypeReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let directory = try? faceTableDirectory(in: handle) else { return false }
        try? handle.close()
        let outlineTags: Set<UInt32> = [0x676C_7966, 0x6C6F_6361]  // 'glyf', 'loca'
        var found: Set<UInt32> = []
        var hasCFF = false
        for entry in directory {
            if outlineTags.contains(entry.tag) { found.insert(entry.tag) }
            if entry.tag == 0x4346_4620 || entry.tag == 0x4346_4632 { hasCFF = true }  // 'CFF ' / 'CFF2'
        }
        return found.count == outlineTags.count || hasCFF
    }

    private struct UnparsableFontFile: Error {}

    /// The first face's table directory. TTC siblings share layout, and Apple's
    /// CJK collections carry identical metrics across faces, so face 0 stands
    /// for the file.
    private static func faceTableDirectory(
        in handle: FileHandle
    ) throws -> [(tag: UInt32, offset: UInt32, length: UInt32)] {
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let header = try handle.read(upToCount: 16), header.count >= 12 else {
            throw UnparsableFontFile()
        }
        var faceOffset: UInt32 = 0
        let tag = u32(header, 0)
        if tag == 0x7474_6366 {  // 'ttcf'
            guard header.count >= 16 else { throw UnparsableFontFile() }
            faceOffset = u32(header, 12)
        } else if tag != 0x0001_0000 && tag != 0x4F54_544F && tag != 0x7472_7565 {
            throw UnparsableFontFile()  // not sfnt-based at all
        }
        try handle.seek(toOffset: UInt64(faceOffset))
        guard let face = try handle.read(upToCount: 12), face.count == 12 else {
            throw UnparsableFontFile()
        }
        let numTables = Int(face[4]) << 8 | Int(face[5])
        guard numTables > 0, numTables < 512,
              let directory = try handle.read(upToCount: numTables * 16),
              directory.count == numTables * 16 else {
            throw UnparsableFontFile()
        }
        return (0..<numTables).map { i in
            (u32(directory, i * 16), u32(directory, i * 16 + 8), u32(directory, i * 16 + 12))
        }
    }

    // MARK: - Metrics

    /// The vertical-metric fields libass actually consumes. Copied verbatim from
    /// the source font file whenever possible: libass sizes and lays out every
    /// font VSFilter-style from OS/2 usWinAscent/usWinDescent (and hhea), so a
    /// subset carrying invented values renders at a different scale and baseline
    /// than the real font would — visible as CJK and Latin disagreeing about
    /// size and line position in the same cue. The hvgl migration only removed
    /// the OUTLINE tables; the metrics tables in those files still parse fine.
    struct FaceMetrics {
        var unitsPerEm: UInt16
        var hheaAscender: Int16
        var hheaDescender: Int16
        var hheaLineGap: Int16
        var typoAscender: Int16
        var typoDescender: Int16
        var typoLineGap: Int16
        var winAscent: UInt16
        var winDescent: UInt16
        var xAvgCharWidth: Int16
    }

    static func faceMetrics(of url: URL) -> FaceMetrics? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let directory = try? faceTableDirectory(in: handle) else { return nil }
        defer { try? handle.close() }

        func table(_ tag: UInt32, atLeast bytes: Int) -> Data? {
            guard let entry = directory.first(where: { $0.tag == tag }),
                  entry.length >= bytes,
                  (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
                  let data = try? handle.read(upToCount: bytes),
                  data.count == bytes else { return nil }
            return data
        }
        func u16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
        }
        func i16(_ data: Data, _ offset: Int) -> Int16 { Int16(bitPattern: u16(data, offset)) }

        guard let head = table(0x6865_6164, atLeast: 20),   // 'head'
              let hhea = table(0x6868_6561, atLeast: 10),   // 'hhea'
              let os2 = table(0x4F53_2F32, atLeast: 78)     // 'OS/2'
        else { return nil }

        return FaceMetrics(
            unitsPerEm: u16(head, 18),
            hheaAscender: i16(hhea, 4),
            hheaDescender: i16(hhea, 6),
            hheaLineGap: i16(hhea, 8),
            typoAscender: i16(os2, 68),
            typoDescender: i16(os2, 70),
            typoLineGap: i16(os2, 72),
            winAscent: u16(os2, 74),
            winDescent: u16(os2, 76),
            xAvgCharWidth: i16(os2, 2)
        )
    }

    // MARK: - Subset assembly

    /// Outlines are requested at the font's own unitsPerEm so path coordinates
    /// ARE font units — no scaling, no rounding drift beyond int truncation.
    private static let synthesisPointSize: CGFloat = 1000

    private struct Glyph {
        var points: [(x: Int16, y: Int16, onCurve: Bool)] = []
        var endPoints: [Int] = []
        var advance: UInt16 = 0
        var bounds: (xMin: Int16, yMin: Int16, xMax: Int16, yMax: Int16) = (0, 0, 0, 0)
        var isEmpty: Bool { points.isEmpty }
    }

    /// Everything extracted from a source font, ready to assemble under any
    /// family name.
    private struct ExtractedFont {
        var glyphs: [Glyph]
        var cmap: [(codepoint: UInt32, glyph: UInt16)]
        var metrics: FaceMetrics
        var sourceFamilyName: String
    }

    /// A minimal TrueType font: glyf/loca outlines, format-12 cmap, and just
    /// enough metadata for FreeType + HarfBuzz + libass' fontselect to index it
    /// by family name. Returns nil when no requested scalar produced a glyph.
    ///
    /// - Parameter familyName: overrides the name-table family — how shadow
    ///   subsets impersonate an authored script's missing font.
    static func subsetFont(
        scalars: [Unicode.Scalar],
        from source: CTFont,
        familyName: String? = nil
    ) -> Data? {
        extractFont(scalars: scalars, from: source).map {
            assemble($0, familyName: familyName ?? $0.sourceFamilyName)
        }
    }

    private static func extractFont(
        scalars: [Unicode.Scalar],
        from source: CTFont
    ) -> ExtractedFont? {
        let upem = CGFloat(CTFontGetUnitsPerEm(source))
        guard upem > 0 else { return nil }
        // Work on an instance SIZED to upem so extracted coordinates are units —
        // compare the point size, not the upem, or a font created at any other
        // size slips through and every coordinate lands at the wrong scale.
        let font = CTFontGetSize(source) == upem
            ? source
            : CTFontCreateCopyWithAttributes(source, upem, nil, nil)

        // codepoint → glyph, deduped: several scalars can share one glyph id.
        var glyphForScalar: [(scalar: Unicode.Scalar, glyph: CGGlyph)] = []
        for scalar in Set(scalars).sorted(by: { $0.value < $1.value }) {
            var chars = Array(String(String.UnicodeScalarView([scalar])).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
                  glyphs[0] != 0 else { continue }
            glyphForScalar.append((scalar, glyphs[0]))
        }
        guard !glyphForScalar.isEmpty else { return nil }

        // Local glyph ids: 0 = .notdef, then source glyphs in first-seen order.
        var localIDForSourceGlyph: [CGGlyph: UInt16] = [:]
        var sourceGlyphs: [CGGlyph] = []
        for entry in glyphForScalar where localIDForSourceGlyph[entry.glyph] == nil {
            localIDForSourceGlyph[entry.glyph] = UInt16(sourceGlyphs.count + 1)
            sourceGlyphs.append(entry.glyph)
        }

        var glyphs: [Glyph] = [Glyph()]  // .notdef
        for sourceGlyph in sourceGlyphs {
            glyphs.append(extractGlyph(sourceGlyph, from: font))
        }

        // Real file metrics when available; otherwise the closest approximation
        // CoreText offers. CoreText can report a different unit grid than the
        // file declares (the hvgl faces normalize to 1000 units against the
        // file's 1028), and the extracted outlines live in CORETEXT's grid — so
        // the file's metrics are rescaled onto it. The ratios, which are all
        // libass consumes, survive exactly.
        let sourceURL = CTFontCopyAttribute(source, kCTFontURLAttribute) as? URL
        let metrics: FaceMetrics
        if let sourceURL, let real = faceMetrics(of: sourceURL), real.unitsPerEm > 0 {
            let scale = upem / CGFloat(real.unitsPerEm)
            func scaled(_ value: Int16) -> Int16 {
                Int16(clamping: Int((CGFloat(value) * scale).rounded()))
            }
            func scaled(_ value: UInt16) -> UInt16 {
                UInt16(clamping: Int((CGFloat(value) * scale).rounded()))
            }
            metrics = FaceMetrics(
                unitsPerEm: UInt16(clamping: Int(upem)),
                hheaAscender: scaled(real.hheaAscender),
                hheaDescender: scaled(real.hheaDescender),
                hheaLineGap: scaled(real.hheaLineGap),
                typoAscender: scaled(real.typoAscender),
                typoDescender: scaled(real.typoDescender),
                typoLineGap: scaled(real.typoLineGap),
                winAscent: scaled(real.winAscent),
                winDescent: scaled(real.winDescent),
                xAvgCharWidth: scaled(real.xAvgCharWidth)
            )
        } else {
            let ascender = Int16(clamping: Int(CTFontGetAscent(font).rounded()))
            let descender = Int16(clamping: -Int(CTFontGetDescent(font).rounded()))
            metrics = FaceMetrics(
                unitsPerEm: UInt16(clamping: Int(upem)),
                hheaAscender: ascender,
                hheaDescender: descender,
                hheaLineGap: 0,
                typoAscender: ascender,
                typoDescender: descender,
                typoLineGap: 0,
                winAscent: UInt16(clamping: Int(ascender)),
                winDescent: UInt16(clamping: -Int(descender)),
                xAvgCharWidth: Int16(clamping: Int(upem) / 2)
            )
        }

        return ExtractedFont(
            glyphs: glyphs,
            cmap: glyphForScalar.map { ($0.scalar.value, localIDForSourceGlyph[$0.glyph]!) },
            metrics: metrics,
            sourceFamilyName: CTFontCopyFamilyName(font) as String
        )
    }

    private static func extractGlyph(_ glyph: CGGlyph, from font: CTFont) -> Glyph {
        var result = Glyph()
        var glyphCopy = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
        result.advance = UInt16(clamping: Int(advance.width.rounded()))

        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return result }

        func add(_ point: CGPoint, onCurve: Bool) {
            result.points.append((Int16(clamping: Int(point.x.rounded())),
                                  Int16(clamping: Int(point.y.rounded())), onCurve))
        }
        var contourStart = 0
        func closeContour() {
            guard result.points.count > contourStart else { return }
            // TrueType contours close implicitly; a trailing point that repeats
            // the contour's first point is redundant.
            let first = result.points[contourStart]
            if let last = result.points.last, result.points.count - contourStart > 1,
               last.x == first.x, last.y == first.y, last.onCurve, first.onCurve {
                result.points.removeLast()
            }
            guard result.points.count > contourStart else { return }
            result.endPoints.append(result.points.count - 1)
            contourStart = result.points.count
        }

        path.applyWithBlock { element in
            let el = element.pointee
            switch el.type {
            case .moveToPoint:
                closeContour()
                add(el.points[0], onCurve: true)
            case .addLineToPoint:
                add(el.points[0], onCurve: true)
            case .addQuadCurveToPoint:
                add(el.points[0], onCurve: false)
                add(el.points[1], onCurve: true)
            case .addCurveToPoint:
                // Cubic → two quadratics (midpoint construction). CoreText's
                // hvgl decode emits pure quadratics, so this is a safety path
                // for classic CFF-sourced outlines only; the approximation is
                // well within subtitle rendering tolerance.
                guard let current = result.points.last else { break }
                let p0 = CGPoint(x: CGFloat(current.x), y: CGFloat(current.y))
                let (c1, c2, p3) = (el.points[0], el.points[1], el.points[2])
                let q1 = CGPoint(x: p0.x + 1.5 * (c1.x - p0.x) * 0.5, y: p0.y + 1.5 * (c1.y - p0.y) * 0.5)
                let q2 = CGPoint(x: p3.x + 1.5 * (c2.x - p3.x) * 0.5, y: p3.y + 1.5 * (c2.y - p3.y) * 0.5)
                let mid = CGPoint(x: (q1.x + q2.x) / 2, y: (q1.y + q2.y) / 2)
                add(q1, onCurve: false)
                add(mid, onCurve: true)
                add(q2, onCurve: false)
                add(p3, onCurve: true)
            case .closeSubpath:
                closeContour()
            @unknown default:
                break
            }
        }
        closeContour()

        if !result.points.isEmpty {
            result.bounds = (
                result.points.map(\.x).min()!, result.points.map(\.y).min()!,
                result.points.map(\.x).max()!, result.points.map(\.y).max()!
            )
        }
        return result
    }

    // MARK: - Binary assembly

    private static func assemble(_ extracted: ExtractedFont, familyName: String) -> Data {
        let glyphs = extracted.glyphs
        let cmap = extracted.cmap
        let metrics = extracted.metrics

        // glyf + loca (long format).
        var glyf = Data()
        var loca = Data()
        for glyph in glyphs {
            loca.appendU32(UInt32(glyf.count))
            guard !glyph.isEmpty else { continue }
            glyf.appendI16(Int16(glyph.endPoints.count))
            glyf.appendI16(glyph.bounds.xMin)
            glyf.appendI16(glyph.bounds.yMin)
            glyf.appendI16(glyph.bounds.xMax)
            glyf.appendI16(glyph.bounds.yMax)
            for end in glyph.endPoints { glyf.appendU16(UInt16(end)) }
            glyf.appendU16(0)  // no instructions
            // Flags: no short/repeat compression — plain int16 deltas throughout.
            for point in glyph.points { glyf.append(point.onCurve ? 0x01 : 0x00) }
            var previous: Int16 = 0
            for point in glyph.points { glyf.appendI16(point.x &- previous); previous = point.x }
            previous = 0
            for point in glyph.points { glyf.appendI16(point.y &- previous); previous = point.y }
            while glyf.count % 4 != 0 { glyf.append(0) }
        }
        loca.appendU32(UInt32(glyf.count))

        // cmap: format 12 only (full Unicode range; FreeType + HarfBuzz native).
        var groups: [(start: UInt32, end: UInt32, glyph: UInt32)] = []
        for entry in cmap.sorted(by: { $0.codepoint < $1.codepoint }) {
            if var last = groups.last,
               entry.codepoint == last.end + 1,
               UInt32(entry.glyph) == last.glyph + (last.end - last.start) + 1 {
                last.end = entry.codepoint
                groups[groups.count - 1] = last
            } else {
                groups.append((entry.codepoint, entry.codepoint, UInt32(entry.glyph)))
            }
        }
        var cmapTable = Data()
        cmapTable.appendU16(0)          // version
        cmapTable.appendU16(1)          // one encoding record
        cmapTable.appendU16(3)          // platform: Windows
        cmapTable.appendU16(10)         // encoding: full Unicode
        cmapTable.appendU32(12)         // subtable offset
        cmapTable.appendU16(12)         // format 12
        cmapTable.appendU16(0)
        cmapTable.appendU32(UInt32(16 + groups.count * 12))
        cmapTable.appendU32(0)          // language
        cmapTable.appendU32(UInt32(groups.count))
        for group in groups {
            cmapTable.appendU32(group.start)
            cmapTable.appendU32(group.end)
            cmapTable.appendU32(group.glyph)
        }

        // head
        let xMin = glyphs.map(\.bounds.xMin).min() ?? 0
        let yMin = glyphs.map(\.bounds.yMin).min() ?? 0
        let xMax = glyphs.map(\.bounds.xMax).max() ?? 0
        let yMax = glyphs.map(\.bounds.yMax).max() ?? 0
        var head = Data()
        head.appendU32(0x0001_0000)     // version
        head.appendU32(0x0001_0000)     // fontRevision
        head.appendU32(0)               // checkSumAdjustment (patched last)
        head.appendU32(0x5F0F_3CF5)     // magicNumber
        head.appendU16(0x0003)          // flags: baseline + lsb at x=0
        head.appendU16(metrics.unitsPerEm)
        head.appendU64(0)               // created
        head.appendU64(0)               // modified
        head.appendI16(xMin); head.appendI16(yMin); head.appendI16(xMax); head.appendI16(yMax)
        head.appendU16(0)               // macStyle
        head.appendU16(8)               // lowestRecPPEM
        head.appendI16(2)               // fontDirectionHint
        head.appendI16(1)               // indexToLocFormat: long
        head.appendI16(0)               // glyphDataFormat

        // hhea + hmtx
        var hhea = Data()
        hhea.appendU32(0x0001_0000)
        hhea.appendI16(metrics.hheaAscender)
        hhea.appendI16(metrics.hheaDescender)
        hhea.appendI16(metrics.hheaLineGap)
        hhea.appendU16(glyphs.map(\.advance).max() ?? 0)
        hhea.appendI16(xMin)            // minLeftSideBearing (approx.)
        hhea.appendI16(0)               // minRightSideBearing (approx.)
        hhea.appendI16(xMax)            // xMaxExtent (approx.)
        hhea.appendI16(1); hhea.appendI16(0)  // caretSlope rise/run
        hhea.appendI16(0)               // caretOffset
        for _ in 0..<4 { hhea.appendI16(0) }
        hhea.appendI16(0)               // metricDataFormat
        hhea.appendU16(UInt16(glyphs.count))  // numberOfHMetrics

        var hmtx = Data()
        for glyph in glyphs {
            hmtx.appendU16(glyph.advance)
            hmtx.appendI16(glyph.isEmpty ? 0 : glyph.bounds.xMin)
        }

        // maxp
        var maxp = Data()
        maxp.appendU32(0x0001_0000)
        maxp.appendU16(UInt16(glyphs.count))
        maxp.appendU16(UInt16(glyphs.map(\.points.count).max() ?? 0))
        maxp.appendU16(UInt16(glyphs.map(\.endPoints.count).max() ?? 0))
        maxp.appendU16(0); maxp.appendU16(0)      // composite points/contours
        maxp.appendU16(2)               // maxZones
        maxp.appendU16(0); maxp.appendU16(0); maxp.appendU16(0)  // twilight/storage/FDEFs
        maxp.appendU16(0); maxp.appendU16(0)      // IDEFs/stack
        maxp.appendU16(0)               // maxSizeOfInstructions
        maxp.appendU16(1); maxp.appendU16(0)      // component elements/depth

        // OS/2 (version 4, minimal but coherent)
        var os2 = Data()
        os2.appendU16(4)
        os2.appendI16(metrics.xAvgCharWidth)
        os2.appendU16(400)              // usWeightClass
        os2.appendU16(5)                // usWidthClass
        os2.appendU16(0)                // fsType: installable
        // Exactly TEN reserved metrics here (4 subscript + 4 superscript +
        // 2 strikeout) — one extra shifts every later field, and libass reads
        // usWinAscent/usWinDescent for its VSFilter-style size normalization,
        // so a misaligned OS/2 renders glyphs at a garbage scale.
        for _ in 0..<10 { os2.appendI16(0) }
        os2.appendI16(0)                // sFamilyClass
        for _ in 0..<10 { os2.append(0) }     // panose
        for _ in 0..<4 { os2.appendU32(0) }   // ulUnicodeRange
        os2.appendU32(0x4E4F_4E45)      // achVendID 'NONE'
        os2.appendU16(0x0040)           // fsSelection: REGULAR
        os2.appendU16(UInt16(truncatingIfNeeded: cmap.map(\.codepoint).min() ?? 0))
        os2.appendU16(UInt16(truncatingIfNeeded: min(cmap.map(\.codepoint).max() ?? 0, 0xFFFF)))
        os2.appendI16(metrics.typoAscender)
        os2.appendI16(metrics.typoDescender)
        os2.appendI16(metrics.typoLineGap)
        os2.appendU16(metrics.winAscent)
        os2.appendU16(metrics.winDescent)
        os2.appendU32(0); os2.appendU32(0)    // ulCodePageRange
        os2.appendI16(0); os2.appendI16(0)    // sxHeight, sCapHeight
        os2.appendU16(0); os2.appendU16(0); os2.appendU16(0)  // default/break char, maxContext

        // name: family under Windows/Unicode — what fontselect indexes by.
        let names: [(id: UInt16, value: String)] = [
            (1, familyName), (2, "Regular"),
            (4, familyName), (6, familyName.replacingOccurrences(of: " ", with: "") + "-Subset"),
        ]
        var nameRecords = Data()
        var nameStrings = Data()
        for name in names {
            let encoded = name.value.data(using: .utf16BigEndian) ?? Data()
            nameRecords.appendU16(3)    // Windows
            nameRecords.appendU16(1)    // Unicode BMP
            nameRecords.appendU16(0x0409)
            nameRecords.appendU16(name.id)
            nameRecords.appendU16(UInt16(encoded.count))
            nameRecords.appendU16(UInt16(nameStrings.count))
            nameStrings.append(encoded)
        }
        var name = Data()
        name.appendU16(0)
        name.appendU16(UInt16(names.count))
        name.appendU16(UInt16(6 + names.count * 12))
        name.append(nameRecords)
        name.append(nameStrings)

        // post v3: no glyph names.
        var post = Data()
        post.appendU32(0x0003_0000)
        post.appendU32(0)               // italicAngle
        post.appendI16(0); post.appendI16(0)  // underline position/thickness
        post.appendU32(0)               // isFixedPitch
        for _ in 0..<4 { post.appendU32(0) }

        // sfnt container.
        var tables: [(tag: String, data: Data)] = [
            ("OS/2", os2), ("cmap", cmapTable), ("glyf", glyf), ("head", head),
            ("hhea", hhea), ("hmtx", hmtx), ("loca", loca), ("maxp", maxp),
            ("name", name), ("post", post),
        ]
        let numTables = UInt16(tables.count)
        // Binary-search header fields (FreeType ignores them, but keep them honest).
        var searchRange: UInt16 = 1
        var selector: UInt16 = 0
        while searchRange * 2 <= numTables { searchRange *= 2; selector += 1 }

        var font = Data()
        font.appendU32(0x0001_0000)
        font.appendU16(numTables)
        font.appendU16(searchRange * 16)
        font.appendU16(selector)
        font.appendU16((numTables - searchRange) * 16)

        var offset = 12 + Int(numTables) * 16
        var directory = Data()
        var body = Data()
        var headOffset = 0
        for i in 0..<tables.count {
            var data = tables[i].data
            while data.count % 4 != 0 { data.append(0) }
            tables[i].data = data
            if tables[i].tag == "head" { headOffset = offset }
            directory.append(contentsOf: tables[i].tag.utf8)
            directory.appendU32(checksum(data))
            directory.appendU32(UInt32(offset))
            directory.appendU32(UInt32(tables[i].data.count))
            body.append(data)
            offset += data.count
        }
        font.append(directory)
        font.append(body)

        // head.checkSumAdjustment over the whole font.
        let total = checksum(font)
        let adjustment = 0xB1B0_AFBA &- total
        let adjustmentOffset = headOffset + 8
        font.replaceSubrange(adjustmentOffset..<adjustmentOffset + 4, with: [
            UInt8(truncatingIfNeeded: adjustment >> 24), UInt8(truncatingIfNeeded: adjustment >> 16),
            UInt8(truncatingIfNeeded: adjustment >> 8), UInt8(truncatingIfNeeded: adjustment),
        ])
        return font
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i + 4 <= data.count {
            sum = sum &+ (UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16
                | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3]))
            i += 4
        }
        if i < data.count {
            var last: UInt32 = 0
            for j in 0..<4 { last = (last << 8) | (i + j < data.count ? UInt32(data[i + j]) : 0) }
            sum = sum &+ last
        }
        return sum
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8)); append(UInt8(truncatingIfNeeded: value))
    }
    mutating func appendI16(_ value: Int16) { appendU16(UInt16(bitPattern: value)) }
    mutating func appendU32(_ value: UInt32) {
        appendU16(UInt16(truncatingIfNeeded: value >> 16)); appendU16(UInt16(truncatingIfNeeded: value))
    }
    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(truncatingIfNeeded: value >> 32)); appendU32(UInt32(truncatingIfNeeded: value))
    }
}
