import Foundation
import os
import ParallaxCore
import ParallaxSubtitles

/// The font directory handed to **VLC's own libass** (`:ssa-fontsdir=`) for SMB/local
/// containers whose embedded ASS/SSA tracks the engine renders itself.
///
/// ## Why the bundle directory alone is not enough
///
/// Verified against VLC 3.0.x `modules/codec/libass.c` (the branch VLCKit builds):
///
/// ```c
/// char *psz_fontsdir = var_InheritString( p_dec, "ssa-fontsdir" );
/// if( psz_fontsdir ) { ass_set_fonts_dir( p_library, psz_fontsdir ); … }
/// …
/// #elif defined( __APPLE__ )
///     const char *psz_font = NULL;              /* We don't ship a default font with VLC */
///     const char *psz_family = "Helvetica Neue"; /* … Arial is not on all Apple platforms */
/// …
/// ass_set_fonts( p_renderer, psz_font, psz_family, ASS_FONTPROVIDER_AUTODETECT, NULL, 0 );
/// ```
///
/// Three facts follow, and they decide this whole file:
///
/// 1. **`ssa-fontsdir` is honoured** — whatever directory we name is scanned and every
///    file in it is `ass_add_font`ed into the library, so our faces are reachable.
/// 2. **The default font PATH is `NULL` on Apple** and there is no option to set it.
///    That is the lever we would have preferred; VLC does not expose it.
/// 3. **The default FAMILY is the hardcoded string `"Helvetica Neue"`.** The module never
///    reads `freetype-font` (that option belongs to the *simple* text renderer, a
///    different module) — grep the file, it is not there.
///
/// libass resolves an author font it cannot find by falling back to that default family,
/// matched **by name** against its font database. No bundled Noto file is named
/// "Helvetica Neue", so an ASS script authored in, say, "A-OTF Shin Go Pro" lands on
/// whatever the system provider offers — the device-dependent fallback the bundled faces
/// exist to eliminate.
///
/// ## The default family has to be a PAN-CJK face
///
/// Fansub scripts name author fonts nothing bundles — that is the normal case, not the
/// edge one — so the face answering to "Helvetica Neue" is what most of a Chinese or
/// Japanese track actually renders from. A Latin face there covers none of it: every CJK
/// glyph falls through to libass' per-glyph SYSTEM fallback, which on iOS resolves kana,
/// hangul, Thai and Arabic but NOT Han. That is the tofu.
///
/// So the renamed face is the design's pan-CJK collection instead: Han, kana, hangul,
/// Latin, Greek and Cyrillic all come out of one bundled file, and the system fallback is
/// never consulted.
///
/// ## What is in a design directory
///
/// A symlink to every bundled face, except the design's own CJK collection, which is a
/// **copy** with exactly one face renamed. The collections are OTCs
/// (`NotoSansCJK-Regular.ttc` carries ten faces, `NotoSerifCJK-Regular.ttc` five), each
/// face with its own `name` table over shared glyph data — so renaming one face leaves the
/// others untouched, and the rewrite is a table append plus a 16-byte directory patch
/// rather than a 20 MB reassembly.
///
/// Which face: the region from `Locale.preferredLanguages` (`fallbackLanguage`). 直 and 令
/// are drawn differently per region and both faces cover both, so this is a choice, not a
/// coverage question — the device's own language order is the best guess available before
/// a single cue is parsed. It is part of the cache path, so changing the language list
/// yields a fresh directory and `pruneStaleRoots` drops the old one.
///
/// **Cost.** ~20 MB (sans) / ~26 MB (serif) of Caches per design directory, each replacing
/// a symlink. Memory-neutral for VLC by construction: libass reads every file in the
/// directory into the library either way, and this is the same file it would have read.
///
/// **Trade.** "Noto Sans CJK SC" (or whichever region wins) no longer exists under its own
/// name in that directory — an explicit `\fnNoto Sans CJK SC` in a VLC-rendered script now
/// resolves through the default family, which is the same face. Nothing else changes.
///
/// **Licensing.** The Noto faces are under the SIL Open Font License 1.1, which permits
/// modified copies provided they are not distributed under the Reserved Font Name. "Noto"
/// is that name, so the rewritten face's name RECORDS carry neither it nor any other Noto
/// string: family "Helvetica Neue" (the string VLC asks for), PostScript name
/// `ParallaxSubtitleFallback-Regular`. The CFF table's own internal font name is left
/// alone — it is not a name libass or FreeType matches faces on, and reaching it would
/// mean rebuilding the one table this design exists to avoid touching. Every other face in
/// the copy keeps its original
/// names — they are unmodified bytes of a file that already ships under the same licence.
/// The copy is generated **on the device, at runtime, into the app's own cache** — it is
/// never shipped, never distributed, and dies with the app's data.
///
/// ## Design is fixed at load
///
/// `ssa-fontsdir` is a media option read once, when libvlc builds the decoder. There is no
/// way to re-point a live one, so a VLC-drawn embedded text track keeps the design that
/// was current when playback started; changing Sans↔Serif mid-playback applies from the
/// next item. (Client-rendered sidecar tracks have no such limit — `PlayerViewModel`
/// rebuilds their renderer on the spot.)
enum VLCSubtitleFonts {

    /// The family VLC's libass module passes `ass_set_fonts` as `default_family` on Apple
    /// platforms. Verbatim from `modules/codec/libass.c`; a rename here has to match it
    /// exactly (libass compares family names case-insensitively but not fuzzily).
    static let libassDefaultFamily = "Helvetica Neue"

    /// PostScript name of the rewritten face. Deliberately free of the OFL Reserved Font
    /// Name — see the licensing note above.
    static let fallbackPostScriptName = "ParallaxSubtitleFallback-Regular"

    /// Bump when the directory layout or the rewrite changes — it is part of the cache
    /// path, so a bump makes the old build's directories unreachable and prunable.
    private static let layoutVersion = "v2"

    /// The directory to hand VLC for `design`. Falls back to the bundle's own font
    /// directory if the cache could not be built: the author-font fallback is then wrong
    /// again, but every *named* Noto family still resolves, which is strictly better than
    /// no directory at all.
    static func directory(for design: SubtitleFontBundle.Design) -> URL {
        prepared[design] ?? SubtitleFontBundle.directoryURL
    }

    /// Build both design directories and drop the previous build's. Idempotent by
    /// construction — the work is a `static let` initializer, so the runtime's one-time
    /// initialization *is* the deduplication (the same discipline as
    /// `SubtitleFontRegistration.registerIfNeeded()`).
    ///
    /// Call this off the main thread at launch: the first touch copies both pan-CJK
    /// collections (~46 MB together), rewrites one `name` table in each, and creates a few
    /// dozen symlinks.
    static func prepareIfNeeded() {
        _ = prepared
    }

    private static let prepared: [SubtitleFontBundle.Design: URL] = build()

    // MARK: - Region

    /// The regional CJK face that answers to `libassDefaultFamily`.
    ///
    /// First hit in the device's own language order wins; a list naming no CJK writing
    /// system takes Japanese, which is the bundle's own default elsewhere
    /// (`symbolFallbackOrder`) and the largest share of the ASS content this path serves.
    /// `preferredLanguages` is a parameter so the choice is testable without touching the
    /// device's real preferences.
    static func fallbackLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> CJKFontPlan.Language {
        preferredLanguages.lazy.compactMap { CJKFontPlan.Language(hintTag: $0) }.first ?? .japanese
    }

    // MARK: - Building

    private static func build() -> [SubtitleFontBundle.Design: URL] {
        let language = fallbackLanguage()
        guard let root = versionedRoot(language: language) else { return [:] }
        pruneStaleRoots(keeping: root)
        return buildDirectories(in: root, language: language)
    }

    /// The build step with its root injected, so a test can drive it against a temp
    /// directory instead of the process' real Caches.
    static func buildDirectories(
        in root: URL, language: CJKFontPlan.Language = fallbackLanguage()
    ) -> [SubtitleFontBundle.Design: URL] {
        var built: [SubtitleFontBundle.Design: URL] = [:]
        for design in SubtitleFontBundle.Design.allCases {
            if let url = buildDirectory(for: design, language: language, in: root) {
                built[design] = url
            }
        }
        return built
    }

    /// `Caches/parallax-vlc-fonts/<build>-<layout>-<region>/`. Keyed by the bundle's build
    /// number as well as the layout tag so a new binary — which may ship different faces —
    /// never reads the previous one's directory, and by the region so a changed language
    /// list rebuilds instead of keeping the wrong Han shapes.
    private static func versionedRoot(language: CJKFontPlan.Language) -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return caches
            .appending(path: cacheDirectoryName, directoryHint: .isDirectory)
            .appending(
                path: "\(build)-\(layoutVersion)-\(language.rawValue)", directoryHint: .isDirectory
            )
    }

    static let cacheDirectoryName = "parallax-vlc-fonts"

    /// Every sibling of the live root is a previous build's copy of the same tens of MB —
    /// `ssa-fontsdir` never looks at them again, so they are pure leakage.
    static func pruneStaleRoots(keeping root: URL) {
        let parent = root.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent != root.lastPathComponent {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// One design's directory: links to every bundled face, with the design's own CJK
    /// collection replaced by a copy whose regional face answers to libass' default family.
    /// A `.complete` marker is written LAST and checked FIRST, so a directory left
    /// half-built by a kill is rebuilt rather than handed to libass.
    private static func buildDirectory(
        for design: SubtitleFontBundle.Design, language: CJKFontPlan.Language, in root: URL
    ) -> URL? {
        let fm = FileManager.default
        let dir = root.appending(path: design.rawValue, directoryHint: .isDirectory)
        let marker = root.appending(
            path: ".\(design.rawValue)-complete", directoryHint: .notDirectory
        )
        if fm.fileExists(atPath: marker.path) { return dir }
        let family = SubtitleFontBundle.family(design: design, script: .cjk(language))
        do {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let source = collectionFileURL(design: design, language: language),
                  let faceIndex = SubtitleFontBundle.faceFamilyNames(in: source).firstIndex(of: family)
            else {
                Log.playback.error("VLC fonts: no \(family, privacy: .public) face to rename")
                return nil
            }
            let renamed = try SFNTNameRewrite.renamed(
                Data(contentsOf: source, options: .mappedIfSafe),
                faceIndex: faceIndex,
                family: libassDefaultFamily,
                postScriptName: fallbackPostScriptName
            )
            for url in SubtitleFontBundle.fileURLs
            where url.lastPathComponent != source.lastPathComponent {
                let link = dir.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
                try fm.createSymbolicLink(at: link, withDestinationURL: url)
            }
            try renamed.write(
                to: dir.appending(path: source.lastPathComponent, directoryHint: .notDirectory),
                options: .atomic
            )
            try Data().write(to: marker, options: .atomic)
            return dir
        } catch {
            Log.playback.error(
                "VLC fonts: \(design.rawValue, privacy: .public) directory failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The pan-CJK collection carrying `language` in `design`, found through the family's
    /// own name rather than a hardcoded file name — the bundle table is the single source
    /// for both. "Noto Sans CJK SC" → the file whose name starts "NotoSansCJK-": the
    /// regional suffix names a FACE, the rest names the collection it lives in.
    private static func collectionFileURL(
        design: SubtitleFontBundle.Design, language: CJKFontPlan.Language
    ) -> URL? {
        let stem = SubtitleFontBundle
            .family(design: design, script: .cjk(language))
            .split(separator: " ").dropLast().joined()
        return SubtitleFontBundle.table[.cjk(language)]?.fileURLs
            .first { $0.lastPathComponent.hasPrefix("\(stem)-") }
    }
}

// MARK: - Orphan cache

extension VLCSubtitleFonts {
    /// The cache directory of the retired `SubtitleFontLocator`, which materialized system
    /// CJK faces before the bundle existed. Its contents are dead weight (tens of MB on a
    /// device that ever played an ASS track) and nothing reads them any more.
    static let retiredLocatorCacheName = "parallax-fonts"

    /// Delete the retired locator's cache once, at launch. Idempotent — a missing
    /// directory is the success case, not an error.
    @discardableResult
    static func pruneRetiredCaches(
        in caches: URL? = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
    ) -> Bool {
        guard let caches else { return false }
        let dir = caches.appending(path: retiredLocatorCacheName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch {
            Log.playback.error(
                "VLC fonts: could not drop \(retiredLocatorCacheName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

// MARK: - sfnt name-table rewrite

/// Rewrites ONE face's `name` table so it reports a different family.
///
/// The one thing libass' font matcher reads off a face is its family name
/// (`matches_family_name`, case-insensitive, from the **Microsoft-platform** name records
/// decoded as UTF-16BE), so replacing that table — and nothing else — is enough to make a
/// bundled Noto face answer to the family VLC asks for.
///
/// **Append, don't reassemble.** The new table goes at the end of the file and the face's
/// 16-byte table-directory record is patched in place (checksum, offset, length). Every
/// other byte — every other face's directory, the shared glyph data — is untouched, which
/// is what makes this affordable on a 26 MB OpenType collection and what makes a
/// collection and a single sfnt the same code: a single sfnt is a collection of one, and
/// its table offsets are file-absolute in exactly the same way. The old table's bytes are
/// left orphaned; nothing references them.
///
/// `head.checkSumAdjustment` is left as the source wrote it: it is a whole-file checksum
/// no rasterizer we ship to validates (FreeType ignores it outright), and recomputing it
/// would buy nothing a font validator we never run would notice.
enum SFNTNameRewrite {
    enum Failure: Error {
        case notAnSFNT
        case truncated
        case noNameTable
        case noSuchFace
    }

    private static let nameTag: UInt32 = 0x6E61_6D65  // 'name'

    /// `data` with face `faceIndex`'s `name` table replaced by a minimal one naming
    /// `family`.
    static func renamed(
        _ data: Data, faceIndex: Int = 0, family: String, postScriptName: String
    ) throws -> Data {
        var bytes = data
        let faces = try faceOffsets(bytes)
        guard faces.indices.contains(faceIndex) else { throw Failure.noSuchFace }
        guard let record = nameRecordOffset(bytes, faceOffset: faces[faceIndex]) else {
            throw Failure.noNameTable
        }

        let table = nameTable(family: family, postScriptName: postScriptName)
        // sfnt table offsets must be long-aligned, so the append starts on a 4-byte
        // boundary and the table is padded out to one.
        bytes.append(contentsOf: repeatElement(UInt8(0), count: (4 - bytes.count % 4) % 4))
        let offset = bytes.count
        bytes.append(contentsOf: table)
        bytes.append(contentsOf: repeatElement(UInt8(0), count: (4 - table.count % 4) % 4))

        write(&bytes, at: record + 4, checksum(table))
        write(&bytes, at: record + 8, UInt32(offset))
        write(&bytes, at: record + 12, UInt32(table.count))
        return bytes
    }

    /// Where each face's table directory starts. A `ttcf` header lists them; a bare sfnt is
    /// one face at 0.
    private static func faceOffsets(_ bytes: Data) throws -> [Int] {
        guard bytes.count >= 12 else { throw Failure.truncated }
        let tag = be32(bytes, 0)
        guard tag == 0x7474_6366 else {  // 'ttcf'
            guard tag == 0x0001_0000 || tag == 0x4F54_544F || tag == 0x7472_7565 else {
                throw Failure.notAnSFNT
            }
            return [0]
        }
        let count = Int(be32(bytes, 8))
        guard count > 0, count < 256, bytes.count >= 12 + 4 * count else { throw Failure.truncated }
        return (0..<count).map { Int(be32(bytes, 12 + 4 * $0)) }
    }

    /// Offset of the 16-byte directory record for that face's `name` table.
    private static func nameRecordOffset(_ bytes: Data, faceOffset: Int) -> Int? {
        guard faceOffset >= 0, bytes.count >= faceOffset + 12 else { return nil }
        let tableCount = Int(be16(bytes, faceOffset + 4))
        guard bytes.count >= faceOffset + 12 + 16 * tableCount else { return nil }
        return (0..<tableCount)
            .map { faceOffset + 12 + 16 * $0 }
            .first { be32(bytes, $0) == nameTag }
    }

    /// A format-0 `name` table with the four records libass and FreeType actually read,
    /// all on the Microsoft platform (3/1/0x409) as UTF-16BE. Typographic names (16/17)
    /// are deliberately absent: an absent record means "use 1/2", which is what we want,
    /// whereas a leftover one would still say Noto.
    private static func nameTable(family: String, postScriptName: String) -> [UInt8] {
        let entries: [(id: UInt16, value: String)] = [
            (1, family),          // family
            (2, "Regular"),       // subfamily
            (4, family),          // full name
            (6, postScriptName),  // PostScript name
        ]
        var storage: [UInt8] = []
        var records: [(id: UInt16, offset: UInt16, length: UInt16)] = []
        for entry in entries {
            var utf16: [UInt8] = []
            for unit in entry.value.utf16 {
                utf16.append(UInt8(unit >> 8))
                utf16.append(UInt8(unit & 0xFF))
            }
            records.append((entry.id, UInt16(storage.count), UInt16(utf16.count)))
            storage.append(contentsOf: utf16)
        }
        var table: [UInt8] = []
        appendBE(&table, UInt16(0))                       // format 0
        appendBE(&table, UInt16(records.count))
        appendBE(&table, UInt16(6 + 12 * records.count))  // stringOffset
        for record in records {
            appendBE(&table, UInt16(3))       // platformID: Microsoft
            appendBE(&table, UInt16(1))       // encodingID: Unicode BMP
            appendBE(&table, UInt16(0x0409))  // languageID: en-US
            appendBE(&table, record.id)
            appendBE(&table, record.length)
            appendBE(&table, record.offset)
        }
        table.append(contentsOf: storage)
        return table
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            var word = UInt32(bytes[i]) << 24
            if i + 1 < bytes.count { word |= UInt32(bytes[i + 1]) << 16 }
            if i + 2 < bytes.count { word |= UInt32(bytes[i + 2]) << 8 }
            if i + 3 < bytes.count { word |= UInt32(bytes[i + 3]) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    private static func be32(_ bytes: Data, _ i: Int) -> UInt32 {
        UInt32(be16(bytes, i)) << 16 | UInt32(be16(bytes, i + 2))
    }

    private static func be16(_ bytes: Data, _ i: Int) -> UInt16 {
        let base = bytes.startIndex
        return UInt16(bytes[base + i]) << 8 | UInt16(bytes[base + i + 1])
    }

    private static func write(_ bytes: inout Data, at i: Int, _ value: UInt32) {
        let base = bytes.startIndex
        bytes[base + i] = UInt8((value >> 24) & 0xFF)
        bytes[base + i + 1] = UInt8((value >> 16) & 0xFF)
        bytes[base + i + 2] = UInt8((value >> 8) & 0xFF)
        bytes[base + i + 3] = UInt8(value & 0xFF)
    }

    private static func appendBE(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value >> 8)); out.append(UInt8(value & 0xFF))
    }
}
