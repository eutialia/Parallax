import Foundation
import CoreMedia
import ParallaxCore

/// Everything `PlayerViewModel.start(smbItem:)` needs to play an SMB file, resolved by the
/// caller so the view model never imports the SMB layer.
public nonisolated struct SMBPlaybackItem: Sendable {
    /// The key `SMBResumeStore` saves and reads local resume positions under.
    public let itemID: ItemID
    /// The local media server's URL for the file. Carries no credentials.
    public let url: URL
    public let title: String
    /// Resume offset from `SMBResumeStore`, or nil for a fresh start. No server holds SMB progress.
    public let startTime: CMTime?
    /// Sibling subtitle files, keyed by a synthetic stream index, mirroring the Jellyfin
    /// path's `subtitleStreamURLs`.
    public let subtitleURLs: [Int: URL]
    /// A menu label per sidecar, keyed the same as `subtitleURLs`. A missing key falls back
    /// to a generated name.
    public let subtitleLabels: [Int: String]
    /// Stops the local media server and releases its SMB reader when the session ends.
    public let cleanup: @Sendable () async -> Void

    public init(
        itemID: ItemID,
        url: URL,
        title: String,
        startTime: CMTime? = nil,
        subtitleURLs: [Int: URL] = [:],
        subtitleLabels: [Int: String] = [:],
        cleanup: @escaping @Sendable () async -> Void = {}
    ) {
        self.itemID = itemID
        self.url = url
        self.title = title
        self.startTime = startTime
        self.subtitleURLs = subtitleURLs
        self.subtitleLabels = subtitleLabels
        self.cleanup = cleanup
    }
}
