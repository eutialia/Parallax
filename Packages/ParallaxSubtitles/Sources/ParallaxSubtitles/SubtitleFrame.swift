import CoreGraphics

/// One composited subtitle frame, ready to be drawn over the video.
public struct SubtitleFrame: Sendable {

    /// The blended subtitle bitmap, or nil when this frame draws nothing and the
    /// overlay should be cleared.
    ///
    /// Premultiplied BGRA in the sRGB space. ASS carries no colour space of its
    /// own and libass leaves HDR mapping undefined, so subtitle colours are
    /// treated as SDR sRGB / BT.709 the way mpv and VLC treat them.
    public let image: CGImage?

    /// Where `image` belongs inside `canvasSize`, in pixels.
    ///
    /// The origin is the TOP-LEFT of the canvas with y growing downward, which is
    /// libass' convention — not CoreGraphics'. A caller drawing into a flipped
    /// CGContext must convert.
    public let imageRect: CGRect

    /// The canvas these coordinates are in, in pixels (points x scale as passed
    /// to `setCanvas`).
    public let canvasSize: CGSize

    public init(image: CGImage?, imageRect: CGRect, canvasSize: CGSize) {
        self.image = image
        self.imageRect = imageRect
        self.canvasSize = canvasSize
    }

    /// True when the frame clears the overlay rather than drawing anything.
    public var isEmpty: Bool { image == nil }
}
