import CSubtitleBlend
import CoreGraphics
import Foundation
import Libass

/// Client-side subtitle rendering on top of libass.
///
/// `ASS_Renderer` and `ASS_Track` are not thread safe and hold mutable caches
/// keyed on the current frame size, so both live inside this actor and never
/// leave it. Only finished frames cross the boundary. The `ASS_Library` they
/// hang off is shared by every renderer in the process (`LibassLibrary`) —
/// registering the ~50 MB font bundle once instead of per pick — so all libass
/// calls, this actor's included, are serialised on that library's lock.
public actor SubtitleRenderer {

    private var engine: LibassEngine?

    private let defaultFontFamily: String
    private var canvasPixelSize: CGSize = .zero
    private var storagePixelSize: CGSize?
    private var styleOverride: SubtitleStyleOverride?
    /// libass reports "nothing changed" from the second render onwards, so the
    /// first frame after any reconfiguration has to be emitted unconditionally.
    private var hasEmittedFrame = false

    /// The family converted scripts are built against when the caller doesn't
    /// choose one. This is the LATIN face: every other script is reached by
    /// per-run `\fn` tagging, not by naming a different style font. The only
    /// other choice is `SubtitleFontBundle.serifFamily`.
    public static let standardFontFamily = SubtitleFontBundle.sansFamily

    /// The synthesized Default style's font size as a fraction of the script
    /// canvas height — what callers remap tuned point sizes against. Exposed so
    /// the app-side mapping can never drift from `ASSScriptBuilder`'s numbers.
    public static var convertedScriptFontFraction: Double {
        Double(ASSScriptBuilder.fontSize) / Double(ASSScriptBuilder.playResY)
    }

    /// The synthesized script's PlayRes canvas, for callers converting device
    /// points into script units (margins are authored against this grid).
    public static var convertedScriptPlayRes: CGSize {
        CGSize(width: ASSScriptBuilder.playResX, height: ASSScriptBuilder.playResY)
    }

    /// - Parameter defaultFontFamily: the font of converted SRT/WebVTT
    ///   sidecars, and libass' fallback family for any name a script requests
    ///   that the bundle does not carry. Only `SubtitleFontBundle` families
    ///   resolve to anything — no system font is reachable.
    public init(defaultFontFamily: String = SubtitleRenderer.standardFontFamily) {
        self.defaultFontFamily = defaultFontFamily
    }

    // MARK: - Loading

    /// - Parameter languageHint: the track's own language label, when known.
    ///   Only a tie-breaker: it decides which Chinese script Han-only lines
    ///   assume when their characters are shared between the two.
    public func load(
        _ data: Data,
        format: SubtitleSourceFormat,
        languageHint: String? = nil
    ) throws {
        let engine = try activeEngine()

        // No bundled file covers every script and no system provider is
        // reachable, so a run libass cannot place draws nothing; and within CJK
        // every regional face covers the whole Han repertoire, so a wrong pick
        // is silent. Routing is therefore planned before libass sees the script
        // and named explicitly, per run.
        var bytes: [UInt8]
        if format.needsConversion {
            guard let text = ASSTextEncoding.utf8(data) else {
                throw SubtitleError.undecodableText
            }
            var events = switch format {
            case .srt: SRTToASSConverter.events(from: text)
            default: WebVTTToASSConverter.events(from: text)
            }
            // Converted text is ours to write: make the choice explicit with
            // \fn so libass matches by family, deterministically.
            let plan = SubtitleFontPlan.build(
                lines: events.flatMap { SubtitleFontTagger.plainLines(of: $0.text) },
                styleFamily: defaultFontFamily,
                languageHint: languageHint
            )
            for index in events.indices {
                events[index].text = SubtitleFontTagger.tagged(
                    events[index].text, plan: plan,
                    styleFontSize: Double(ASSScriptBuilder.fontSize)
                )
            }
            bytes = Array(ASSScriptBuilder.script(events: events, fontFamily: defaultFontFamily).utf8)
        } else if let script = ASSTextEncoding.utf8(data) ?? ASSTextEncoding.decoded(data) {
            // Legacy fansub encodings (GBK/Big5/Shift_JIS/EUC-KR) are decoded
            // and re-emitted as UTF-8 rather than handed to libass' iconv path:
            // raw, the substitution pre-pass cannot parse them, so every style
            // collapses onto `default_family` and every line onto the bare
            // Japanese face.
            let scan = ASSScriptScan.scan(script: script)
            let plan = SubtitleFontPlan.build(
                lines: scan.plainLines,
                styleFamily: defaultFontFamily,
                languageHint: languageHint
            )
            // The author's fonts are not ours and never will be. Their names
            // are translated onto the bundle — serif intent preserved, every
            // other field untouched.
            bytes = Array(
                AuthoredFontSubstitution.applied(to: script, plan: plan, scan: scan).utf8
            )
        } else {
            // Nothing decoded it: hand libass the raw bytes and let its own
            // iconv try. It renders through `default_family`, so it loses the
            // per-style serif routing and every per-run face, but it renders.
            bytes = Array(data)
        }
        guard !bytes.isEmpty else { throw SubtitleError.noCues }

        registerFonts(for: bytes, format: format, engine: engine)
        try engine.loadTrack(bytes: &bytes)
        hasEmittedFrame = false
    }

    /// Registers the bundled files this script's families live in, and re-runs
    /// `ass_set_fonts` if that added any.
    ///
    /// Both halves have to happen BEFORE `ass_read_memory`-then-render: the
    /// library only copies a font when it is registered, and a renderer's
    /// `fontselect` only sees what the library held when `ass_set_fonts` last
    /// ran. The families are read back off the script we are about to hand
    /// libass, so the set is exactly what `fontselect` will ask for — except on
    /// the raw-bytes path, where nothing parsed and the whole bundle has to be
    /// available.
    private func registerFonts(
        for bytes: [UInt8], format: SubtitleSourceFormat, engine: LibassEngine
    ) {
        let files: [URL]
        if let script = String(data: Data(bytes), encoding: .utf8) {
            var families = ASSScriptScan.requestedFamilies(in: script)
            if let override = styleOverride?.fontFamily { families.insert(override) }
            families.insert(defaultFontFamily)
            files = SubtitleFontBundle.files(forFamilies: families)
        } else {
            files = SubtitleFontBundle.fileURLs
        }
        LibassLibrary.shared.ensureRegistered(files: files, log: engine.messageLog)
        engine.refreshFontsIfNeeded()
    }

    // MARK: - Canvas

    /// - Parameters:
    ///   - size: overlay size in points.
    ///   - scale: points to pixels. `size * scale` is the pixel canvas frames come back in.
    ///   - storageSize: the video's native pixel dimensions. libass needs them to scale
    ///     `\pos`, borders and blurs the way the script's author saw them; passing nil
    ///     makes libass guess.
    public func setCanvas(size: CGSize, scale: CGFloat, storageSize: CGSize?) {
        let pixels = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        canvasPixelSize = pixels.width >= 1 && pixels.height >= 1 ? pixels : .zero
        storagePixelSize = storageSize
        hasEmittedFrame = false
        // Laying out the overlay must not construct libass and enumerate every
        // system font; `activeEngine` replays these settings when it builds one.
        if let engine { applyCanvas(to: engine) }
    }

    private func applyCanvas(to engine: LibassEngine) {
        guard canvasPixelSize != .zero else { return }
        let frame = (Self.dimension(canvasPixelSize.width), Self.dimension(canvasPixelSize.height))
        let storage = (
            Self.dimension(storagePixelSize?.width ?? 0),
            Self.dimension(storagePixelSize?.height ?? 0)
        )
        engine.withRenderer { renderer in
            ass_set_frame_size(renderer, frame.0, frame.1)
            ass_set_storage_size(renderer, storage.0, storage.1)
        }
    }

    /// Narrows a pixel dimension for libass without trapping.
    ///
    /// `storageSize` comes from a media file's own header, so a corrupt or hostile
    /// file can hand us a nonsense width. Anything unrepresentable becomes zero,
    /// which libass reads as "unset" for the storage size and as "cannot render"
    /// for the frame size — both far better outcomes than crashing the player.
    private static func dimension(_ value: CGFloat) -> Int32 {
        guard value.isFinite, value > 0, value <= CGFloat(Int32.max) else { return 0 }
        return Int32(value.rounded())
    }

    // MARK: - Style override

    /// - Parameter override: nil leaves the script's own styling untouched. That
    ///   is the only correct answer for an AUTHORED script: its colours, sizes,
    ///   borders and placement are someone else's typesetting, and the one thing
    ///   we change about it — the typeface, whose files we do not have — is
    ///   already done at load by `AuthoredFontSubstitution`. An override belongs
    ///   to converted SRT/WebVTT, whose script we synthesized ourselves.
    public func setStyleOverride(_ override: SubtitleStyleOverride?) {
        styleOverride = override
        hasEmittedFrame = false
        // Only pushed through if the engine already exists; otherwise `activeEngine`
        // replays the stored settings when it builds one.
        if let engine { applyStyleOverride(to: engine) }
    }

    private func applyStyleOverride(to engine: LibassEngine) {
        guard let override = styleOverride, !override.isNoOp else {
            engine.withRenderer { renderer in
                ass_set_selective_style_override_enabled(
                    renderer, Int32(ASS_OVERRIDE_DEFAULT.rawValue)
                )
                ass_set_font_scale(renderer, 1)
            }
            return
        }

        // The override names a family past every substitution, and it can be set
        // after the track loaded — so its file has to be registered here too,
        // not only from `load`. No-op when it already is.
        if let family = override.fontFamily {
            LibassLibrary.shared.ensureRegistered(
                files: SubtitleFontBundle.files(forFamilies: [family]), log: engine.messageLog
            )
            engine.refreshFontsIfNeeded()
        }

        // libass DOES copy FontName, so ours is ours to release. It does not copy
        // Name — see LibassEngine.overrideStyleName for why that one outlives us.
        guard let font = strdup(override.fontFamily ?? defaultFontFamily) else { return }
        defer { free(font) }

        // Only the fields matching an enabled override bit are ever read, so the
        // rest stay zero. Enabling a new bit means filling in its fields too:
        // ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS wants FontSize/Spacing/ScaleX/ScaleY.
        let boxed = override.opaqueBox == true
        var style = ASS_Style()
        style.Name = engine.overrideStyleName
        style.FontName = font
        style.PrimaryColour = (override.primaryColor ?? SubtitleColor(red: 1, green: 1, blue: 1)).assPacked
        style.SecondaryColour = SubtitleColor(red: 1, green: 0, blue: 0).assPacked
        style.OutlineColour = (override.outlineColor ?? SubtitleColor(red: 0, green: 0, blue: 0)).assPacked
        // At BorderStyle 3 this is the box fill and has to be fully opaque;
        // otherwise it is only the drop shadow, where the caller's opacity (or
        // half transparency) reads better.
        style.BackColour = SubtitleColor(
            red: 0, green: 0, blue: 0,
            alpha: boxed ? 1 : (override.shadowAlpha ?? 0.5)
        ).assPacked

        if override.overridesBorder {
            // 3 = opaque box, 1 = outline + shadow. At 3 the Outline field stops
            // being a stroke width and becomes the box's padding, so the same
            // proportion the synthesized style uses carries straight over.
            let border = borderGeometry(override)
            style.BorderStyle = boxed ? 3 : 1
            style.Outline = border.outline
            style.Shadow = boxed ? 0 : border.shadow
        }

        if override.overridesMargins {
            // One flag covers all three margins, so every field is filled: an
            // unset side would otherwise replace the authored margin with zero.
            style.MarginV = Int32((override.marginVertical ?? 0).rounded())
            style.MarginL = Int32((override.marginHorizontal ?? 0).rounded())
            style.MarginR = Int32((override.marginHorizontal ?? 0).rounded())
        }

        engine.withRenderer { renderer in
            ass_set_selective_style_override(renderer, &style)
            ass_set_selective_style_override_enabled(renderer, override.overrideBits)
            ass_set_font_scale(renderer, override.fontScale ?? 1)
        }
    }

    /// Resolves the override's em-relative border geometry into the script units
    /// libass wants.
    ///
    /// The em is the size the text really renders at, in the script's own units.
    /// Only CONVERTED scripts are ever overridden and those are ours, authored
    /// at `ASSScriptBuilder.fontSize` on a 720-line canvas — so the caller's
    /// canvas fraction resolves straight against that canvas.
    private func borderGeometry(_ override: SubtitleStyleOverride) -> (outline: Double, shadow: Double) {
        let em = (override.emHeightRatio ?? Self.convertedScriptFontFraction)
            * Double(ASSScriptBuilder.playResY)
        return (
            outline: override.outlineEmRatio.map { $0 * em } ?? ASSScriptBuilder.outlineWidth,
            shadow: override.shadowEmRatio.map { $0 * em } ?? ASSScriptBuilder.shadowOffset
        )
    }

    // MARK: - Rendering

    /// - Returns: the frame to display, or nil when nothing has changed since the
    ///   last call. Cheap enough to poll every display refresh: libass' own change
    ///   detection short-circuits before any compositing happens.
    public func frame(at seconds: Double) -> SubtitleFrame? {
        // A non-finite clock would trap in the millisecond conversion below;
        // "nothing to show" is the honest answer to a nonsense time.
        guard seconds.isFinite else { return nil }
        guard let engine, engine.track != nil, canvasPixelSize != .zero else { return nil }

        var changed: Int32 = 0
        let images = engine.renderFrame(
            atMilliseconds: Int64((seconds * 1000).rounded()),
            changed: &changed
        )
        if hasEmittedFrame, changed == 0 { return nil }
        hasEmittedFrame = true

        let blend = subtitle_blend_images(images)
        guard !blend.is_empty, let pixels = blend.pixels else {
            return SubtitleFrame(image: nil, imageRect: .zero, canvasSize: canvasPixelSize)
        }
        guard let image = makeImage(from: blend, pixels: pixels) else {
            return SubtitleFrame(image: nil, imageRect: .zero, canvasSize: canvasPixelSize)
        }

        return SubtitleFrame(
            image: image,
            imageRect: CGRect(
                x: CGFloat(blend.x),
                y: CGFloat(blend.y),
                width: CGFloat(blend.width),
                height: CGFloat(blend.height)
            ),
            canvasSize: canvasPixelSize
        )
    }

    /// Takes ownership of `pixels`. Once the provider exists it owns the buffer and
    /// frees it via the release callback, whether or not the CGImage is built; if
    /// the provider itself cannot be created, this frees the buffer directly.
    private func makeImage(
        from blend: SubtitleBlendResult,
        pixels: UnsafeMutablePointer<UInt8>
    ) -> CGImage? {
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: pixels,
            size: blend.byte_count,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        ) else {
            free(pixels)
            return nil
        }

        return CGImage(
            width: Int(blend.width),
            height: Int(blend.height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: blend.bytes_per_row,
            // Named sRGB, not device RGB: ASS carries no colour space and libass
            // leaves HDR undefined, so the documented contract is sRGB / BT.709.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Diagnostics

    /// libass' captured message log (font selection, parse warnings). Empty until
    /// the engine exists. The only ground truth for which font a glyph run used —
    /// a missing glyph renders as a perfectly valid tofu box.
    public var diagnosticLog: [String] { engine?.messageLog.lines ?? [] }

    // MARK: - Engine lifecycle

    /// Built on first use so a renderer that is never fed anything costs nothing,
    /// and configured from whatever was set before it existed.
    private func activeEngine() throws -> LibassEngine {
        if let engine { return engine }
        guard let engine = LibassEngine(defaultFontFamily: defaultFontFamily) else {
            throw SubtitleError.engineUnavailable
        }
        self.engine = engine
        applyCanvas(to: engine)
        applyStyleOverride(to: engine)
        return engine
    }
}
