import Foundation
import ParallaxCore

/// One still frame from a video URL. The SMB artwork pipeline drives `AVThumbnailer` through this
/// so scenarios can substitute a recording fake.
@MainActor
public protocol FrameThumbnailing: Sendable {
    /// - Throws: `CancellationError` when the caller was cancelled, a `ThumbnailError` otherwise.
    func frame(from url: URL, at position: Float, timeout: Duration) async throws -> ThumbnailFrame
}

/// A thumbnailer failure that says whether the engine gave up waiting, which is evidence about the
/// link, as opposed to failing on the content itself.
public protocol ThumbnailError: Error {
    var isTimeout: Bool { get }
}
