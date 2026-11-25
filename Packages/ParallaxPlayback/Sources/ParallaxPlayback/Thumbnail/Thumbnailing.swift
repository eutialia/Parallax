import Foundation
import ParallaxCore

/// A tile's picture of a video file. The SMB artwork pipeline drives `MediaThumbnailer` through
/// this so scenarios can substitute a recording fake.
public protocol Thumbnailing: Sendable {
    /// Stops at its next packet once its task is cancelled; a read stuck in the reader holds it
    /// until that read returns, so the caller bounds the wait.
    /// - Throws: `CancellationError` when cancelled, `MediaThumbnailer.Failure` when the file gave
    ///   no picture, and the reader's or the container's own error otherwise.
    func thumbnail(of reader: any RandomAccessReading) async throws -> ThumbnailFrame
}
