import AetherLibavfilter
import AetherLibavutil

/// Makes whole pictures of frames stored as two fields, one picture for each field, through
/// libavfilter's bwdif. A frame the decoder does not mark as fields passes through as one
/// picture.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class Deinterlacer {
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private let source: UnsafeMutablePointer<AVFilterContext>
    private let sink: UnsafeMutablePointer<AVFilterContext>
    private let picture: UnsafeMutablePointer<AVFrame>
    private let shape: (width: Int32, height: Int32, format: Int32)

    private static let nanoseconds = AVRational(num: 1, den: 1_000_000_000)

    /// For frames of `frame`'s size and pixel format, timed in nanoseconds.
    init(for frame: UnsafePointer<AVFrame>) throws(VideoDecoder.Failure) {
        guard let graph = avfilter_graph_alloc() else { throw .outOfMemory }
        self.graph = graph
        var made: (UnsafeMutablePointer<AVFilterContext>?, UnsafeMutablePointer<AVFilterContext>?, UnsafeMutablePointer<AVFilterContext>?)
        let frames = "video_size=\(frame.pointee.width)x\(frame.pointee.height):pix_fmt=\(frame.pointee.format)"
            + ":time_base=1/1000000000:pixel_aspect=1/1"
            + ":colorspace=\(frame.pointee.colorspace.rawValue):range=\(frame.pointee.color_range.rawValue)"
        var status = avfilter_graph_create_filter(&made.0, avfilter_get_by_name("buffer"), "in", frames, nil, graph)
        if status >= 0 {
            // A picture for each field, and only of the frames marked as fields.
            status = avfilter_graph_create_filter(
                &made.1, avfilter_get_by_name("bwdif"), "fields", "mode=send_field:parity=auto:deint=interlaced", nil, graph)
        }
        if status >= 0 {
            status = avfilter_graph_create_filter(&made.2, avfilter_get_by_name("buffersink"), "out", nil, nil, graph)
        }
        if status >= 0 { status = avfilter_link(made.0, 0, made.1, 0) }
        if status >= 0 { status = avfilter_link(made.1, 0, made.2, 0) }
        if status >= 0 { status = avfilter_graph_config(graph, nil) }
        guard status >= 0, let source = made.0, let sink = made.2 else {
            avfilter_graph_free(&self.graph)
            throw .deinterlacer(code: status)
        }
        guard let picture = av_frame_alloc() else {
            avfilter_graph_free(&self.graph)
            throw .outOfMemory
        }
        self.source = source
        self.sink = sink
        self.picture = picture
        shape = (frame.pointee.width, frame.pointee.height, frame.pointee.format)
    }

    /// Whether `frame` has the size and pixel format the filter was made for.
    func takes(_ frame: UnsafePointer<AVFrame>) -> Bool {
        shape == (frame.pointee.width, frame.pointee.height, frame.pointee.format)
    }

    deinit {
        var picture: UnsafeMutablePointer<AVFrame>? = picture
        av_frame_free(&picture)
        avfilter_graph_free(&graph)
    }

    /// The pictures the filter gives once it has `frame`: those of the frame before it, since
    /// a field is filled in from the fields on both sides of it. The second field of a frame
    /// is timed halfway to the next frame.
    func push(_ frame: UnsafeMutablePointer<AVFrame>, into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        let status = av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
        guard status >= 0 else { throw VideoDecoder.Failure.deinterlacer(code: status) }
        try drain(into: take)
    }

    /// The pictures of the last frame, when the stream has no more.
    func finish(into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        guard av_buffersrc_add_frame_flags(source, nil, 0) >= 0 else { return }
        try drain(into: take)
    }

    private func drain(into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        while av_buffersink_get_frame(sink, picture) >= 0 {
            defer { av_frame_unref(picture) }
            // The filter counts time in half the units it was handed.
            if picture.pointee.pts != VideoDecoder.noTime {
                picture.pointee.pts = av_rescale_q(picture.pointee.pts, av_buffersink_get_time_base(sink), Self.nanoseconds)
            }
            try take(picture)
        }
    }
}
