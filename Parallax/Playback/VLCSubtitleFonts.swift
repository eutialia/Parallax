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
/// ## The minimal correct thing
///
/// Since the family string is the only lever, we make it resolve to Noto: a copy of
/// `NotoSans-Regular.ttf` / `NotoSerif-Regular.ttf` with its `name` table rewritten so it
/// reports family "Helvetica Neue", dropped into a cache directory alongside links to the
/// rest of the bundle. `:ssa-fontsdir` points there, libass finds the renamed face in its
/// own database before it ever consults CoreText, and an unknown author font renders in
/// the design the user picked.
///
/// **Licensing.** The Noto faces are under the SIL Open Font License 1.1, which permits
/// modified copies provided they are not distributed under the Reserved Font Name. "Noto"
/// is that name, so the rewritten face carries neither it nor any other Noto string: its
/// family is "Helvetica Neue" (the string VLC asks for) and its PostScript name is
/// `ParallaxSubtitleFallback-Regular`. The copy is generated **on the device, at runtime,
/// into the app's own cache** — it is never shipped, never distributed, and dies with the
/// app's data.
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

    /// File name of the rewritten face inside each design directory.
    static let fallbackFileName = "ParallaxSubtitleFallback-Regular.ttf"

    /// Bump when the directory layout or the rewrite changes — it is part of the cache
    /// path, so a bump makes the old build's directories unreachable and prunable.
    private static let layoutVersion = "v1"

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
    /// Call this off the main thread at launch: the first touch copies ~700 KB, rewrites a
    /// name table and creates a few dozen symlinks.
    static func prepareIfNeeded() {
        _ = prepared
    }

    private static let prepared: [SubtitleFontBundle.Design: URL] = build()

    // MARK: - Building

    private static func build() -> [SubtitleFontBundle.Design: URL] {
        guard let root = versionedRoot() else { return [:] }
        pruneStaleRoots(keeping: root)
        return buildDirectories(in: root)
    }

    /// The build step with its root injected, so a test can drive it against a temp
    /// directory instead of the process' real Caches.
    static func buildDirectories(in root: URL) -> [SubtitleFontBundle.Design: URL] {
        var built: [SubtitleFontBundle.Design: URL] = [:]
        for design in SubtitleFontBundle.Design.allCases {
            if let url = buildDirectory(for: design, in: root) { built[design] = url }
        }
        return built
    }

    /// `Caches/parallax-vlc-fonts/<build>-<layout>/`. Keyed by the bundle's build number
    /// as well as the layout tag so a new binary — which may ship different faces — never
    /// reads the previous one's directory.
    private static func versionedRoot() -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return caches
            .appending(path: cacheDirectoryName, directoryHint: .isDirectory)
            .appending(path: "\(build)-\(layoutVersion)", directoryHint: .isDirectory)
    }

    static let cacheDirectoryName = "parallax-vlc-fonts"

    /// Every sibling of the live root is a previous build's copy of the same ~700 KB —
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

    /// One design's directory: links to every bundled face, plus the renamed default.
    /// A `.complete` marker is written LAST and checked FIRST, so a directory left
    /// half-built by a kill is rebuilt rather than handed to libass.
    private static func buildDirectory(
        for design: SubtitleFontBundle.Design, in root: URL
    ) -> URL? {
        let fm = FileManager.default
        let dir = root.appending(path: design.rawValue, directoryHint: .isDirectory)
        let marker = root.appending(path: ".\(design.rawValue)-complete", directoryHint: .notDirectory)
        if fm.fileExists(atPath: marker.path) { return dir }
        do {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in SubtitleFontBundle.fileURLs {
                let link = dir.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
                try fm.createSymbolicLink(at: link, withDestinationURL: url)
            }
            guard let source = latinFileURL(design) else {
                Log.playback.error("VLC fonts: no Latin face for \(design.rawValue, privacy: .public)")
                return nil
            }
            let renamed = try SFNTNameRewrite.renamed(
                Data(contentsOf: source),
                family: libassDefaultFamily,
                postScriptName: fallbackPostScriptName
            )
            try renamed.write(
                to: dir.appending(path: fallbackFileName, directoryHint: .notDirectory),
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

    /// The bundle's Latin face for a design, found by the family's own name rather than a
    /// hardcoded file name — the bundle table is the single source for both.
    private static func latinFileURL(_ design: SubtitleFontBundle.Design) -> URL? {
        let stem = SubtitleFontBundle
            .family(design: design, script: .common)
            .replacingOccurrences(of: " ", with: "")
        return SubtitleFontBundle.table[.common]?.fileURLs
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

/// Rewrites an sfnt's `name` table so the face reports a different family.
///
/// The one thing libass' font matcher reads off a face is its family name
/// (`matches_family_name`, case-insensitive, from the **Microsoft-platform** name records
/// decoded as UTF-16BE), so replacing that table — and nothing else — is enough to make a
/// bundled Noto face answer to the family VLC asks for. Glyphs, metrics and layout tables
/// are copied through byte for byte; only the directory offsets and per-table checksums
/// are recomputed.
enum SFNTNameRewrite {
    enum Failure: Error {
        case notAnSFNT
        case truncated
        case noNameTable
    }

    private static let nameTag: UInt32 = 0x6E61_6D65  // 'name'

    /// `data` with its `name` table replaced by a minimal one naming `family`.
    ///
    /// Single-face sfnts only — a TrueType *collection* (`ttcf`) shares tables between
    /// faces and would need every face's directory rewritten, which nothing here needs
    /// (the default-family fallback is a Latin face, and both are plain `.ttf`).
    static func renamed(_ data: Data, family: String, postScriptName: String) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw Failure.truncated }
        let version = be32(bytes, 0)
        guard version == 0x0001_0000 || version == 0x4F54_544F else { throw Failure.notAnSFNT }
        let tableCount = Int(be16(bytes, 4))
        guard bytes.count >= 12 + 16 * tableCount else { throw Failure.truncated }

        var tables: [(tag: UInt32, body: [UInt8])] = []
        tables.reserveCapacity(tableCount)
        for i in 0..<tableCount {
            let entry = 12 + 16 * i
            let tag = be32(bytes, entry)
            let offset = Int(be32(bytes, entry + 8))
            let length = Int(be32(bytes, entry + 12))
            guard offset >= 0, length >= 0, offset + length <= bytes.count else { throw Failure.truncated }
            tables.append((tag, Array(bytes[offset..<(offset + length)])))
        }
        guard let nameIndex = tables.firstIndex(where: { $0.tag == nameTag }) else {
            throw Failure.noNameTable
        }
        tables[nameIndex].body = nameTable(family: family, postScriptName: postScriptName)
        // The directory must be sorted by tag; a rewrite in place keeps whatever order
        // the source had, which is already sorted for every real font — sort anyway so a
        // sloppy source can't produce a file FreeType rejects.
        tables.sort { $0.tag < $1.tag }
        return assemble(version: version, tables: tables)
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

    private static func assemble(version: UInt32, tables: [(tag: UInt32, body: [UInt8])]) -> Data {
        let n = tables.count
        var pow2 = 1, exponent = 0
        while pow2 * 2 <= n { pow2 *= 2; exponent += 1 }

        var header: [UInt8] = []
        appendBE(&header, version)
        appendBE(&header, UInt16(n))
        appendBE(&header, UInt16(pow2 * 16))          // searchRange
        appendBE(&header, UInt16(exponent))           // entrySelector
        appendBE(&header, UInt16(n * 16 - pow2 * 16)) // rangeShift

        var directory: [UInt8] = []
        var body: [UInt8] = []
        var offset = 12 + 16 * n
        for table in tables {
            appendBE(&directory, table.tag)
            appendBE(&directory, checksum(table.body))
            appendBE(&directory, UInt32(offset))
            appendBE(&directory, UInt32(table.body.count))
            body.append(contentsOf: table.body)
            let padded = (table.body.count + 3) & ~3
            body.append(contentsOf: repeatElement(0, count: padded - table.body.count))
            offset += padded
        }
        // `head.checkSumAdjustment` is left as the source wrote it: it is a whole-file
        // checksum no rasterizer we ship to validates (FreeType ignores it outright), and
        // recomputing it would buy nothing a font validator we never run would notice.
        return Data(header + directory + body)
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

    private static func be32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
    }

    private static func be16(_ bytes: [UInt8], _ i: Int) -> UInt16 {
        UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
    }

    private static func appendBE(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value >> 8)); out.append(UInt8(value & 0xFF))
    }

    private static func appendBE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF)); out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF)); out.append(UInt8(value & 0xFF))
    }
}
