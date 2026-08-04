import CoreGraphics
import CoreText
import Foundation

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
enum SystemGlyphFont {

    /// One synthesized subset: the family name libass should index it under and
    /// the TrueType blob.
    struct Subset {
        let familyName: String
        let data: Data
    }

    /// Character classes worth checking: from CJK Radicals (U+2E80) up. Latin,
    /// Cyrillic, Greek, Arabic … all still ship as classic font files that
    /// FreeType opens directly, so scanning them would only cost time.
    static func candidateScalars(in text: String) -> Set<Unicode.Scalar> {
        var scalars: Set<Unicode.Scalar> = []
        for scalar in text.unicodeScalars where scalar.value >= 0x2E80 {
            scalars.insert(scalar)
        }
        return scalars
    }

    /// Builds subsets for every font CoreText would use for `scalars` (cascading
    /// from `baseFamily`) whose backing FILE FreeType cannot read. Families with
    /// readable files need nothing — libass finds them through its own provider.
    static func unreadableFamilySubsets(
        for scalars: Set<Unicode.Scalar>,
        baseFamily: String
    ) -> [Subset] {
        guard !scalars.isEmpty else { return [] }
        let base = CTFontCreateWithName(baseFamily as CFString, Self.synthesisPointSize, nil)

        // Group the scalars by the font CoreText cascades to for each of them.
        var groups: [String: (font: CTFont, url: URL?, scalars: [Unicode.Scalar])] = [:]
        for scalar in scalars {
            let string = String(String.UnicodeScalarView([scalar]))
            let resolved = CTFontCreateForString(base, string as CFString, CFRange(location: 0, length: string.utf16.count))
            let family = CTFontCopyFamilyName(resolved) as String
            if groups[family] == nil {
                let url = CTFontCopyAttribute(resolved, kCTFontURLAttribute) as? URL
                groups[family] = (resolved, url, [])
            }
            groups[family]?.scalars.append(scalar)
        }

        return groups.compactMap { family, group in
            // A file FreeType can open needs no help. A font with no file URL at
            // all (registered in-memory by the system) can only be reached here.
            if let url = group.url, fileIsFreeTypeReadable(url) { return nil }
            guard let data = subsetFont(scalars: group.scalars, from: group.font) else { return nil }
            return Subset(familyName: family, data: data)
        }
    }

    /// FreeType reads a face iff its outlines live in `glyf`(+`loca`) or
    /// `CFF `/`CFF2`. Checked by parsing the sfnt table directory directly —
    /// deterministic, no FreeType round trip, and honest about future Apple
    /// format migrations (a font that drops these tables fails this check the
    /// day it ships).
    static func fileIsFreeTypeReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16), header.count >= 12 else { return false }
        defer { try? handle.close() }

        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | UInt32($1) }
        }

        var faceOffset: UInt32 = 0
        let tag = u32(header, 0)
        if tag == 0x7474_6366 {  // 'ttcf' — check the first face; siblings share layout
            faceOffset = u32(header, 12)
        } else if tag != 0x0001_0000 && tag != 0x4F54_544F && tag != 0x7472_7565 {
            return false  // not sfnt-based at all
        }

        guard (try? handle.seek(toOffset: UInt64(faceOffset))) != nil,
              let face = try? handle.read(upToCount: 12), face.count == 12 else { return false }
        let numTables = Int(face[4]) << 8 | Int(face[5])
        guard numTables > 0, numTables < 512,
              let directory = try? handle.read(upToCount: numTables * 16),
              directory.count == numTables * 16 else { return false }

        var hasGlyf = false, hasLoca = false, hasCFF = false
        for i in 0..<numTables {
            switch u32(directory, i * 16) {
            case 0x676C_7966: hasGlyf = true   // 'glyf'
            case 0x6C6F_6361: hasLoca = true   // 'loca'
            case 0x4346_4620, 0x4346_4632: hasCFF = true  // 'CFF ' / 'CFF2'
            default: break
            }
        }
        return (hasGlyf && hasLoca) || hasCFF
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

    /// A minimal TrueType font: glyf/loca outlines, format-12 cmap, and just
    /// enough metadata for FreeType + HarfBuzz + libass' fontselect to index it
    /// by family name. Returns nil when no requested scalar produced a glyph.
    static func subsetFont(scalars: [Unicode.Scalar], from source: CTFont) -> Data? {
        let upem = CGFloat(CTFontGetUnitsPerEm(source))
        // Work on an instance sized to upem so extracted coordinates are units.
        let font = upem == synthesisPointSize
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

        let ascender = Int16(clamping: Int(CTFontGetAscent(font).rounded()))
        let descender = Int16(clamping: -Int(CTFontGetDescent(font).rounded()))
        let familyName = CTFontCopyFamilyName(font) as String

        return assemble(
            glyphs: glyphs,
            cmap: glyphForScalar.map { ($0.scalar.value, localIDForSourceGlyph[$0.glyph]!) },
            unitsPerEm: UInt16(clamping: Int(upem)),
            ascender: ascender,
            descender: descender,
            familyName: familyName
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

    private static func assemble(
        glyphs: [Glyph],
        cmap: [(codepoint: UInt32, glyph: UInt16)],
        unitsPerEm: UInt16,
        ascender: Int16,
        descender: Int16,
        familyName: String
    ) -> Data {
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
        head.appendU16(unitsPerEm)
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
        hhea.appendI16(ascender)
        hhea.appendI16(descender)
        hhea.appendI16(0)               // lineGap
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
        os2.appendI16(Int16(unitsPerEm / 2))  // xAvgCharWidth (approx.)
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
        os2.appendI16(ascender)         // sTypoAscender
        os2.appendI16(descender)        // sTypoDescender
        os2.appendI16(0)                // sTypoLineGap
        os2.appendU16(UInt16(clamping: Int(ascender)))   // usWinAscent
        os2.appendU16(UInt16(clamping: -Int(descender))) // usWinDescent
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
