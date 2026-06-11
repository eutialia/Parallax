import Foundation
import CoreText
import os
import ParallaxCore

/// Materializes **system** fonts for VLC's libass (ASS/SSA) subtitle renderer.
///
/// libass on iOS has no font provider (no fontconfig, and this VLCKit build ships no
/// CoreText font-manager module). Reading the VLC + libass source settles how fonts
/// must be supplied:
///
/// - VLC's libass module calls `ass_set_fonts(renderer, NULL, "Helvetica Neue",
///   AUTODETECT, NULL, 0)` on Apple platforms — a null default-font path and a family
///   default of **"Helvetica Neue"**, with no usable provider.
/// - libass `find_font` only ever selects a face that matches the requested family **by
///   name** (`matches_family_name`, case-insensitive); glyph coverage is a *filter
///   among name-matched faces*, never a way to reach an unnamed face. With no provider
///   and no default-font path, the only reachable fallback is the family default.
/// - `get_font_info` reads a face's family from its **Microsoft-platform** name records
///   (nameID 1 / 4), decoded as UTF-16BE.
///
/// Therefore: extract the CJK system faces (the sandbox blocks reading the font *files*,
/// but `CTFontCopyTable` still returns each table's bytes, so we rebuild valid sfnts) and
/// **rewrite each one's `name` table so its family is "Helvetica Neue"**. libass then
/// resolves every unmatched subtitle font to our directory via the family default, and —
/// since both faces share that family — picks whichever covers each codepoint (JP/Latin
/// from the JP face, Simplified Chinese from the GB face). No bundled binary; OS fonts only.
///
/// Resolved once per process; files are reused across launches (the `version` tag busts
/// the cache when this logic changes).
///
/// `nonisolated`: under the app target's default MainActor isolation, the lazy
/// `fonts` initializer would otherwise run its CoreText table copies, checksums,
/// and disk writes on the main thread — mid-presentation on a first play. Callers
/// on the start path go through `resolved()`, which forces the first touch onto
/// the global executor.
nonisolated enum SubtitleFontLocator {
    /// The libass font directory plus a single file for VLC's simple (SRT) text
    /// renderer, which is a separate module taking `:freetype-font=`.
    struct Fonts {
        let directory: URL    // :ssa-fontsdir — libass scans this for fallbacks
        let primaryFile: URL  // :freetype-font — the simple text renderer
    }

    static let fonts: Fonts? = resolve()

    /// Off-main access to `fonts`: the first touch materializes font files
    /// (CTFontCopyTable over megabytes of CJK tables + atomic writes), far too
    /// heavy for the MainActor. Later calls return the memoized value.
    @concurrent static func resolved() async -> Fonts? { fonts }

    /// The family name VLC passes libass as its default on Apple platforms. Our fonts
    /// are renamed to this so libass's family-default lookup resolves to them.
    private static let libassDefaultFamily = "Helvetica Neue"

    /// Bump when the materialization logic changes, to invalidate cached files.
    private static let version = "hn1"

    /// System faces to materialize, broad coverage first. Each carries Latin too, so
    /// English subtitles render from any of them. Both are Hiragino faces: a single-face
    /// Hiragino sfnt reassembles cleanly, whereas PingFang ships as an OpenType-CFF
    /// *collection* that FreeType rejects after single-face reassembly. The JP face covers
    /// kana + kanji (incl. many Traditional forms) + Latin; the GB face covers Simplified.
    private static let sources: [(label: String, make: () -> CTFont?)] = [
        ("system-ja", { CTFontCreateUIFontForLanguage(.system, 24, "ja" as CFString) }),
        ("HiraginoGB", { CTFontCreateWithName("HiraginoSansGB-W6" as CFString, 24, nil) }),
    ]

    private static func fileName(for label: String) -> String { "\(label)-\(version).ttf" }

    private static func resolve() -> Fonts? {
        guard let dir = fontsDirectory() else { return nil }
        pruneStaleFonts(in: dir)
        var primary: URL?
        for source in sources where materialize(source, into: dir) != nil {
            if primary == nil { primary = dir.appendingPathComponent(fileName(for: source.label)) }
        }
        guard let primary else {
            Log.playback.warning("SubtitleFontLocator: no system font materialized; VLC text subtitles will not render")
            return nil
        }
        return Fonts(directory: dir, primaryFile: primary)
    }

    /// Remove font files not produced by the current `sources`/`version`. `ssa-fontsdir`
    /// scans the whole directory, so a stale leftover (an old name-table revision, or the
    /// discarded ~59 MB PingFang reassembly) would still be loaded by libass.
    private static func pruneStaleFonts(in dir: URL) {
        let keep = Set(sources.map { fileName(for: $0.label) })
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "ttf" && !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A dedicated subdirectory so `ssa-fontsdir` only ever sees our font files.
    private static func fontsDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("parallax-fonts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.playback.error("SubtitleFontLocator: can't create fonts dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return dir
    }

    /// Reuse a prior extraction if present; otherwise extract the font's sfnt (with its
    /// family renamed to the libass default) and write it atomically.
    @discardableResult
    private static func materialize(_ source: (label: String, make: () -> CTFont?), into dir: URL) -> URL? {
        let url = dir.appendingPathComponent(fileName(for: source.label))
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 4096 {
            return url
        }
        guard let font = source.make() else { return nil }
        let postscript = "HelveticaNeue-" + source.label.filter(\.isLetter)
        guard let data = sfntData(from: font, familyOverride: libassDefaultFamily, postscript: postscript),
              data.count > 4096 else {
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.playback.error("SubtitleFontLocator: write failed for \(source.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return url
    }

    /// Rebuild a complete sfnt (TrueType/OpenType) from a CTFont's tables, optionally
    /// replacing the `name` table so the face reports `familyOverride`. The font file
    /// isn't readable under the sandbox, but `CTFontCopyTable` still returns each table's
    /// bytes — enough to assemble a valid font on disk for FreeType.
    private static func sfntData(from font: CTFont, familyOverride: String?, postscript: String) -> Data? {
        guard let tagArray = CTFontCopyAvailableTables(font, []) else { return nil }
        let count = CFArrayGetCount(tagArray)
        guard count > 0 else { return nil }

        // Tags are stored unboxed: (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex.
        var tags: [CTFontTableTag] = []
        tags.reserveCapacity(count)
        for i in 0..<count {
            let bits = UInt(bitPattern: CFArrayGetValueAtIndex(tagArray, i))
            tags.append(CTFontTableTag(truncatingIfNeeded: bits))
        }

        // Copy each table's bytes (directory must end up sorted by tag).
        var tables: [(tag: CTFontTableTag, data: Data)] = []
        tables.reserveCapacity(tags.count)
        for tag in tags.sorted() {
            guard let table = CTFontCopyTable(font, tag, []) else { continue }
            tables.append((tag, table as Data))
        }
        guard !tables.isEmpty else { return nil }

        // Swap in a synthetic 'name' table so libass matches this face by family.
        if let familyOverride {
            let nameTag: CTFontTableTag = 0x6E61_6D65 // 'name'
            let nameData = nameTable(family: familyOverride, postscript: postscript)
            if let idx = tables.firstIndex(where: { $0.tag == nameTag }) {
                tables[idx].data = nameData
            } else {
                tables.append((nameTag, nameData))
                tables.sort { $0.tag < $1.tag }
            }
        }

        let isCFF = tables.contains { $0.tag == 0x4346_4620 }       // 'CFF '
        let sfntVersion: UInt32 = isCFF ? 0x4F54_544F : 0x0001_0000 // 'OTTO' : 1.0

        let n = tables.count
        var pow2 = 1, exp = 0
        while pow2 * 2 <= n { pow2 *= 2; exp += 1 }
        let searchRange = UInt16(pow2 * 16)
        let entrySelector = UInt16(exp)
        let rangeShift = UInt16(n * 16 - pow2 * 16)

        var header = Data()
        header.appendBE(sfntVersion)
        header.appendBE(UInt16(n))
        header.appendBE(searchRange)
        header.appendBE(entrySelector)
        header.appendBE(rangeShift)

        var directory = Data()
        var body = Data()
        var offset = 12 + 16 * n
        for table in tables {
            directory.appendBE(table.tag)
            directory.appendBE(checksum(table.data))
            directory.appendBE(UInt32(offset))
            directory.appendBE(UInt32(table.data.count))
            body.append(table.data)
            let padded = (table.data.count + 3) & ~3
            if padded > table.data.count {
                body.append(Data(count: padded - table.data.count))
            }
            offset += padded
        }

        var sfnt = Data(capacity: header.count + directory.count + body.count)
        sfnt.append(header)
        sfnt.append(directory)
        sfnt.append(body)
        return sfnt
    }

    /// Build a minimal format-0 `name` table. libass reads family/full names only from
    /// **Microsoft-platform** records (platform 3, encoding 1, language 0x409) as UTF-16BE,
    /// so that's all we emit: family + subfamily + full + PostScript name.
    private static func nameTable(family: String, postscript: String) -> Data {
        let entries: [(nameID: UInt16, value: String)] = [
            (1, family),     // Font Family
            (2, "Regular"),  // Font Subfamily
            (4, family),     // Full name
            (6, postscript), // PostScript name
        ]

        var storage = Data()
        var records: [(nameID: UInt16, offset: UInt16, length: UInt16)] = []
        for entry in entries {
            var bytes = Data()
            for unit in entry.value.utf16 { bytes.appendBE(unit) } // UTF-16BE
            records.append((entry.nameID, UInt16(storage.count), UInt16(bytes.count)))
            storage.append(bytes)
        }

        var table = Data()
        table.appendBE(UInt16(0))                      // format 0
        table.appendBE(UInt16(records.count))          // count
        table.appendBE(UInt16(6 + 12 * records.count)) // stringOffset
        for record in records {
            table.appendBE(UInt16(3))      // platformID = Microsoft
            table.appendBE(UInt16(1))      // encodingID = Unicode BMP
            table.appendBE(UInt16(0x0409)) // languageID = en-US
            table.appendBE(record.nameID)
            table.appendBE(record.length)
            table.appendBE(record.offset)
        }
        table.append(storage)
        return table
    }

    /// sfnt table checksum: the sum (mod 2^32) of the table's big-endian uint32 words,
    /// with the final partial word zero-padded.
    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            var sum: UInt32 = 0
            let n = raw.count
            var i = 0
            while i < n {
                var word = UInt32(raw[i]) << 24
                if i + 1 < n { word |= UInt32(raw[i + 1]) << 16 }
                if i + 2 < n { word |= UInt32(raw[i + 2]) << 8 }
                if i + 3 < n { word |= UInt32(raw[i + 3]) }
                sum = sum &+ word
                i += 4
            }
            return sum
        }
    }
}

private nonisolated extension Data {
    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    mutating func appendBE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
