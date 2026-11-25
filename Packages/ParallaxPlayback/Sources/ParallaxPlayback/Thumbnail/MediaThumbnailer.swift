import CoreGraphics
import Foundation
import ParallaxCore

/// A tile's picture of a video file in any container the bridge reads: its cover art when it
/// carries one, and otherwise its picture at the keyframe a seek to 5% in lands on, past a black
/// leader. One keyframe is read and decoded, nothing is served.
public struct MediaThumbnailer: Thumbnailing {
    public enum Failure: Error, Equatable {
        /// The decoder gave no picture of the frames read from the keyframe.
        case noPicture
    }

    /// A cover is a poster, kept as large as a sidecar poster is.
    static let coverMaxPixel = 1280

    public init() {}

    /// Cancellation is checked between steps as well as at each packet: the open and the cover
    /// walk do not see it.
    public func thumbnail(of reader: any RandomAccessReading) async throws -> ThumbnailFrame {
        try Task.checkCancellation()
        let cache = SessionBlockCache(reader: reader, size: try await reader.fileSize)
        let demuxer = try await MediaDemuxer.open(cache, skippingAttachments: true)
        try Task.checkCancellation()
        let duration = demuxer.duration.map(Duration.nanoseconds)
        // Skipping attachments drops Matroska's cover with the fonts, so it is found by walking
        // to it instead.
        let cover = demuxer.isMatroska ? try await MatroskaCoverArt.extract(reader) : await demuxer.attachedPicture()
        try Task.checkCancellation()
        if let poster = cover.flatMap(Self.poster) {
            return ThumbnailFrame(data: try ImageTranscode.encodeHEIC(poster), duration: duration)
        }
        let picture = try await demuxer.picture(
            near: ThumbnailPosition.time(start: demuxer.start, duration: demuxer.duration))
        return ThumbnailFrame(data: try ImageTranscode.encodeHEIC(picture), duration: duration)
    }

    private static func poster(_ data: Data) -> CGImage? {
        ImageTranscode.downscaledImage(from: data, maxPixelSize: coverMaxPixel)
    }
}

/// Where in a file its thumbnail is taken.
enum ThumbnailPosition {
    /// Nanoseconds of the file's own time: 5% in, or the start when the file gives no length.
    static func time(start: Int64, duration: Int64?) -> Int64 {
        start + max(duration ?? 0, 0) / 20
    }
}
