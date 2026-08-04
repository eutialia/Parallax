import CSubtitleBlend
import CoreGraphics
import Foundation
import Libass

/// Client-side subtitle rendering on top of libass.
///
/// `ASS_Library`, `ASS_Renderer` and `ASS_Track` are not thread safe and hold
/// mutable caches keyed on the current frame size, so all three live inside this
/// actor and never leave it. Only finished frames cross the boundary.
public actor SubtitleRenderer {

    private var engine: LibassEngine?

    private let defaultFontFamily: String
    private let defaultFontURL: URL?
    private var canvasPixelSize: CGSize = .zero
    private var storagePixelSize: CGSize?
    private var styleOverride: SubtitleStyleOverride?
    /// libass reports "nothing changed" from the second render onwards, so the
    /// first frame after any reconfiguration has to be emitted unconditionally.
    private var hasEmittedFrame = false

    /// - Parameters:
    ///   - defaultFontFamily: used when a script names a font that is not
    ///     installed, and as the font of converted SRT/WebVTT sidecars.
    ///   - defaultFontURL: a font FILE handed to libass as the last-resort face
    ///     for glyphs nothing else covers. Defaults to the bundled CJK fallback.
    public init(
        defaultFontFamily: String = "Helvetica Neue",
        defaultFontURL: URL? = SubtitleFallbackFont.bundledURL
    ) {
        self.defaultFontFamily = defaultFontFamily
        self.defaultFontURL = defaultFontURL
    }

    // MARK: - Loading

    public func load(_ data: Data, format: SubtitleSourceFormat) throws {
        let engine = try activeEngine()

        var bytes: [UInt8]
        if format.needsConversion {
            guard let text = String(data: data, encoding: .utf8) else {
                throw SubtitleError.undecodableText
            }
            let script = switch format {
            case .srt: SRTToASSConverter.script(from: text, fontFamily: defaultFontFamily)
            default: WebVTTToASSConverter.script(from: text, fontFamily: defaultFontFamily)
            }
            bytes = Array(script.utf8)
        } else {
            bytes = Array(data)
        }
        guard !bytes.isEmpty else { throw SubtitleError.noCues }

        try engine.loadTrack(bytes: &bytes)
        hasEmittedFrame = false
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
        ass_set_frame_size(
            engine.renderer,
            Self.dimension(canvasPixelSize.width),
            Self.dimension(canvasPixelSize.height)
        )
        ass_set_storage_size(
            engine.renderer,
            Self.dimension(storagePixelSize?.width ?? 0),
            Self.dimension(storagePixelSize?.height ?? 0)
        )
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

    /// - Parameter override: nil leaves the script's own styling untouched, which
    ///   is the default and the right choice for authored ASS.
    public func setStyleOverride(_ override: SubtitleStyleOverride?) {
        styleOverride = override
        hasEmittedFrame = false
        // Only pushed through if the engine already exists; otherwise `activeEngine`
        // replays the stored settings when it builds one.
        if let engine { applyStyleOverride(to: engine) }
    }

    private func applyStyleOverride(to engine: LibassEngine) {
        let renderer = engine.renderer

        guard let override = styleOverride, !override.isNoOp else {
            ass_set_selective_style_override_enabled(renderer, Int32(ASS_OVERRIDE_DEFAULT.rawValue))
            ass_set_font_scale(renderer, 1)
            return
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
        // otherwise it is only the drop shadow, where half transparency reads better.
        style.BackColour = SubtitleColor(red: 0, green: 0, blue: 0, alpha: boxed ? 1 : 0.5).assPacked

        if override.overridesBorder {
            // 3 = opaque box, 1 = outline + shadow. At 3 the Outline field stops
            // being a stroke width and becomes the box's padding, so the same
            // proportion the synthesized style uses carries straight over.
            style.BorderStyle = boxed ? 3 : 1
            style.Outline = ASSScriptBuilder.outlineWidth
            style.Shadow = boxed ? 0 : ASSScriptBuilder.shadowOffset
        }

        ass_set_selective_style_override(renderer, &style)
        ass_set_selective_style_override_enabled(renderer, override.overrideBits)
        ass_set_font_scale(renderer, override.fontScale ?? 1)
    }

    // MARK: - Rendering

    /// - Returns: the frame to display, or nil when nothing has changed since the
    ///   last call. Cheap enough to poll every display refresh: libass' own change
    ///   detection short-circuits before any compositing happens.
    public func frame(at seconds: Double) -> SubtitleFrame? {
        guard let engine, engine.track != nil, canvasPixelSize != .zero else { return nil }

        var changed: Int32 = 0
        let images = ass_render_frame(
            engine.renderer,
            engine.track,
            Int64((seconds * 1000).rounded()),
            &changed
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
        guard let engine = LibassEngine(
            defaultFontFamily: defaultFontFamily,
            defaultFontPath: defaultFontURL?.path
        ) else {
            throw SubtitleError.engineUnavailable
        }
        self.engine = engine
        applyCanvas(to: engine)
        applyStyleOverride(to: engine)
        return engine
    }
}
