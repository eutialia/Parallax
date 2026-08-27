import Foundation

/// The only fonts subtitles are ever rendered with.
///
/// libass runs with `ASS_FONTPROVIDER_NONE`, so no system face is reachable
/// from any rendering path — what a subtitle looks like is decided entirely by
/// the files shipped here. That is the point: CoreText's per-glyph fallback
/// answers depend on the device's preferred-languages list, which made one
/// Chinese line render from two different designs on one device and one design
/// on another. Bundled faces make the answer identical everywhere.
///
/// The bundle is **all Noto**, one type family programme end to end: a Latin
/// sans/serif pair covering Latin/Greek/Cyrillic (Vietnamese and Latin Extended
/// included), the two pan-CJK OTCs, and a sans/serif pair per additional
/// writing system — a serif where Noto draws one, the sans in both roles where
/// it does not (Arabic is served by Noto Naskh Arabic in both, the reading face
/// for running text).
///
/// Because no single file covers everything, coverage is a ROUTING problem:
/// `SubtitleScript` classifies every run of a line and the tagger names the
/// family for that run's script, so nothing is ever left to a fallback lottery
/// that `ASS_FONTPROVIDER_NONE` would lose outright.
public enum SubtitleFontBundle {

    public enum Design: String, Sendable, CaseIterable {
        case sans
        case serif
    }

    /// A writing system the bundle carries a face for.
    ///
    /// `.common` is the Latin/Greek/Cyrillic bucket the style font itself
    /// serves — runs classified into it are never tagged, because they already
    /// render from the family the style names.
    public enum Script: Hashable, Sendable {
        case common
        case cjk(CJKFontPlan.Language)
        case thai
        case arabic
        case hebrew
        case devanagari
        case bengali
        case tamil
        case telugu
        case kannada
        case malayalam
        case gujarati
        case gurmukhi
        case sinhala
        case khmer
        case lao
        case myanmar
        case georgian
        case armenian
        case oriya

        /// Every script in the table, CJK expanded per language.
        public static let allCases: [Script] =
            [.common]
            + CJKFontPlan.Language.allCases.map(Script.cjk)
            + [
                .thai, .arabic, .hebrew, .devanagari, .bengali, .tamil, .telugu,
                .kannada, .malayalam, .gujarati, .gurmukhi, .sinhala, .khmer,
                .lao, .myanmar, .georgian, .armenian, .oriya,
            ]
    }

    /// One row of the bundle: the family serving a script in each design, and
    /// the files those families live in.
    ///
    /// `sans` and `serif` are the same string wherever Noto draws only one
    /// design for the script — the face then serves both roles rather than
    /// leaving a serif caption without glyphs.
    public struct Entry: Hashable, Sendable {
        public let sans: String
        public let serif: String
        public let fileNames: [String]

        public var fileURLs: [URL] { fileNames.compactMap(SubtitleFontBundle.fileURL(named:)) }

        init(sans: String, serif: String, files: [String]) {
            self.sans = sans
            self.serif = serif
            self.fileNames = files
        }

        /// One face in both roles — Arabic (Naskh is the reading face) and any
        /// script Noto ships no serif for.
        init(both family: String, file: String) {
            self.init(sans: family, serif: family, files: [file])
        }

        func family(_ design: Design) -> String { design == .serif ? serif : sans }
    }

    /// Script → families + files. Every family string here is nameID 1 of a
    /// shipped face, pinned against the files themselves by
    /// `BundledFontTests.tableNamesMatchTheFiles` — read out, never assumed.
    public static let table: [Script: Entry] = {
        var table: [Script: Entry] = [
            .common: Entry(
                sans: "Noto Sans", serif: "Noto Serif",
                files: ["NotoSans-Regular.ttf", "NotoSerif-Regular.ttf"]
            ),
            // One face for both designs: Naskh is the style Arabic running text
            // is read in, and Noto Sans Arabic is a display companion, not a
            // serif counterpart.
            .arabic: Entry(both: "Noto Naskh Arabic", file: "NotoNaskhArabic-Regular.ttf"),
        ]
        for language in CJKFontPlan.Language.allCases {
            table[.cjk(language)] = Entry(
                sans: "Noto Sans CJK \(language.cjkFaceSuffix)",
                serif: "Noto Serif CJK \(language.cjkFaceSuffix)",
                files: ["NotoSansCJK-Regular.ttc", "NotoSerifCJK-Regular.ttc"]
            )
        }
        for (script, name) in pairedScripts {
            table[script] = Entry(
                sans: "Noto Sans \(name)", serif: "Noto Serif \(name)",
                files: ["NotoSans\(name)-Regular.ttf", "NotoSerif\(name)-Regular.ttf"]
            )
        }
        return table
    }()

    /// Scripts whose sans and serif are the regular `Noto Sans X` / `Noto Serif X`
    /// pair — family names and file names both derive from the script word.
    private static let pairedScripts: [(Script, String)] = [
        (.thai, "Thai"), (.hebrew, "Hebrew"), (.devanagari, "Devanagari"),
        (.bengali, "Bengali"), (.tamil, "Tamil"), (.telugu, "Telugu"),
        (.kannada, "Kannada"), (.malayalam, "Malayalam"), (.gujarati, "Gujarati"),
        (.gurmukhi, "Gurmukhi"), (.sinhala, "Sinhala"), (.khmer, "Khmer"),
        (.lao, "Lao"), (.myanmar, "Myanmar"), (.georgian, "Georgian"),
        (.armenian, "Armenian"), (.oriya, "Oriya"),
    ]

    /// The Latin faces — what a converted script's synthesized style names and
    /// what every untagged run renders from.
    public static let sansFamily = "Noto Sans"
    public static let serifFamily = "Noto Serif"

    /// The on-disk directory holding the fonts — what a second libass (VLC's
    /// internal one) takes as `:ssa-fontsdir`. Fonts only: libass'
    /// `load_fonts_from_dir` calls `ass_add_font` on every file it finds, so the
    /// licence text ships in the app's `Resources/Licenses/` instead.
    public static var directoryURL: URL {
        Bundle.module.url(forResource: fontsDirectoryName, withExtension: nil)
            ?? Bundle.module.bundleURL.appending(path: fontsDirectoryName)
    }

    /// The family serving `script` in `design`. Falls back to the Latin face for
    /// a script the bundle has no row for — the honest answer, since that face
    /// is what libass would reach through `default_family` anyway.
    public static func family(design: Design, script: Script) -> String {
        table[script]?.family(design) ?? (design == .serif ? serifFamily : sansFamily)
    }

    /// The family a track's DEFAULT style lands on: the CJK region face when the
    /// track has a CJK language, the Latin face when it has none.
    ///
    /// A nil language is not "Japanese": Noto's Latin and CJK faces are
    /// separate files, so a Thai or Greek track must name the Latin one and let
    /// per-run routing add the rest.
    public static func family(design: Design, language: CJKFontPlan.Language?) -> String {
        guard let language else { return family(design: design, script: .common) }
        return family(design: design, script: .cjk(language))
    }

    /// Registers the LATIN faces with libass ahead of the first subtitle pick.
    ///
    /// Only those two: `ass_add_font` memcpy's what it is given into the
    /// process-wide library and never releases it, so registering all 39 files
    /// would cost ~52 MB of resident memory for a track that is almost always
    /// Latin-only. Every other file is added on demand by
    /// `LibassLibrary.ensureRegistered` once a loaded track is known to need it.
    ///
    /// Idempotent — the library bootstraps exactly once whoever asks first — and
    /// safe to call from anywhere: the work happens on a detached task.
    /// `.userInitiated`, not `.utility`: the bootstrap takes the process-wide
    /// libass lock, which does not donate priority, so a background warm-up can
    /// hold up the first real pick.
    public static func warmUp() { _ = warmUpTask() }

    /// `warmUp`, with a handle to await. Tests need the completion; production
    /// callers deliberately do not.
    @discardableResult
    static func warmUpTask() -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            _ = LibassLibrary.shared.perform(log: nil) { _ in }
            _ = facesByFamily
        }
    }

    /// Which design a family name belongs to. Anything that is not a Noto Serif
    /// face is served by Sans — including names nothing in the bundle matches,
    /// which libass resolves through `default_family` anyway.
    public static func design(forFamily family: String) -> Design {
        family.hasPrefix(serifFamily) ? .serif : .sans
    }

    // MARK: - Files

    private static let fontsDirectoryName = "Fonts"

    private static func fileURL(named name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: "\(fontsDirectoryName)/\(base)", withExtension: ext)
    }

    /// Every font file in the bundle's directory, in name order.
    ///
    /// Read from the directory rather than from `table`, deliberately: what
    /// libass must index is "everything we ship", and deriving that from the
    /// routing table would let a file added to `Fonts/` be silently unreachable.
    /// The two are cross-checked by a test instead.
    public static var fileURLs: [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { ["ttf", "ttc", "otf", "otc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The files whose faces a track naming `families` will ask libass for, plus
    /// the Latin pair, which is always registered (it is `default_font` and the
    /// last resort under `default_family`).
    ///
    /// A name the bundle does not carry contributes nothing — libass resolves it
    /// through `default_family`, which is one of the Latin faces.
    static func files(forFamilies families: Set<String>) -> [URL] {
        var names = Set(latinFileNames)
        for family in families {
            guard let entry = table.values.first(where: { $0.sans == family || $0.serif == family })
            else { continue }
            names.formUnion(entry.fileNames)
        }
        return fileURLs.filter { names.contains($0.lastPathComponent) }
    }

    /// The two faces every renderer needs whatever the track: the synthesized
    /// style's font, libass' `default_font` file, and `default_family`.
    static let latinFileNames = ["NotoSans-Regular.ttf", "NotoSerif-Regular.ttf"]

    static var latinFileURLs: [URL] {
        fileURLs.filter { latinFileNames.contains($0.lastPathComponent) }
    }

    /// Files to hand libass, mapped rather than read: they total ~52 MB and
    /// libass copies whatever it indexes, so there is no reason to hold a second
    /// heap copy of our own.
    static func registrations(for urls: [URL]) -> [(name: String, data: Data)] {
        urls.compactMap { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return (url.lastPathComponent, data)
        }
    }

    /// libass' last-resort `default_font` — a FILE, not a family, needed because
    /// every system provider is off. The Latin sans: it is the face the
    /// synthesized style names, so the fallback and the default agree.
    static var defaultFontPath: String? { fileURL(named: "NotoSans-Regular.ttf")?.path }

    // MARK: - Metrics

    /// Every bundled face keyed by the family libass matches it under. Parsed
    /// once: the files are memory-mapped and only their tables are touched, but
    /// a track load asks for this several times.
    static let facesByFamily: [String: SFNTFace.Face] = {
        var faces: [String: SFNTFace.Face] = [:]
        for url in fileURLs {
            for face in SFNTFace.faces(of: url) { faces[face.familyName] = face }
        }
        return faces
    }()

    static func metrics(forFamily family: String) -> SFNTFace.Metrics? {
        facesByFamily[family]?.metrics
    }

    // MARK: - Coverage

    /// Whether `family` can draw `scalar`, from that face's own `cmap`. False
    /// for a family the bundle does not carry: nothing is known about it, and
    /// claiming coverage would route a run into tofu.
    static func covers(_ scalar: UInt32, family: String) -> Bool {
        facesByFamily[family]?.coverage.contains(scalar) ?? false
    }

    /// The families of `design`, ordered as a symbol fallback should try them:
    /// the CJK face of the track's own region first (it carries the widest
    /// symbol repertoire in the bundle and is the face the track's own text
    /// already renders from), then the other CJK regions, then the script faces
    /// by name. Deterministic by construction — the order is the routing, and a
    /// fallback that varied by device is the lottery this bundle exists to end.
    static func symbolFallbackOrder(
        design: Design, language: CJKFontPlan.Language?
    ) -> [String] {
        let preferred = language ?? .japanese
        let cjkOrder = [preferred] + CJKFontPlan.Language.allCases.filter { $0 != preferred }
        let cjk = cjkOrder.map { family(design: design, script: .cjk($0)) }
        let others = Script.allCases
            .filter { if case .cjk = $0 { false } else { true } }
            .map { family(design: design, script: $0) }
            .sorted()
        var seen: Set<String> = []
        return (cjk + others).filter { seen.insert($0).inserted }
    }
}

extension CJKFontPlan.Language {
    /// The suffix Noto's pan-CJK collections name their regional faces with —
    /// `Noto Sans CJK JP`, ` KR`, ` SC`, ` TC`. There is no bare face: every
    /// region is suffixed, JP included.
    var cjkFaceSuffix: String {
        switch self {
        case .japanese: "JP"
        case .korean: "KR"
        case .simplifiedChinese: "SC"
        case .traditionalChinese: "TC"
        }
    }
}
