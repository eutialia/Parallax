import Foundation
import ParallaxCore

/// One still frame from a video URL, whichever engine decodes it. The SMB artwork pipeline drives
/// both `AVThumbnailer` and the VLC thumbnailer through this, so it never links the VLC engine.
@MainActor
public protocol FrameThumbnailing: Sendable {
    /// - Parameter container: what the caller's probe identified, nil when it did not. An engine
    ///   whose demuxer choice depends on the container reads it; the others ignore it.
    /// - Throws: `CancellationError` when the caller was cancelled, a `ThumbnailError` otherwise.
    func frame(from url: URL, at position: Float, container: Container?, timeout: Duration) async throws -> ThumbnailFrame
}

/// A thumbnailer failure that says whether the engine gave up waiting, which is evidence about the
/// link, as opposed to failing on the content itself.
public protocol ThumbnailError: Error {
    var isTimeout: Bool { get }
}
