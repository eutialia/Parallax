import Foundation
import CoreMedia
import ParallaxCore
import ParallaxSubtitles

/// A text subtitle stored in the played file, which the app draws from the lines the bridge
/// reads out of it.
public nonisolated struct FileSubtitle: Sendable {
    public enum Format: Sendable { case ass, srt }

    /// The stream's place in the file.
    public let stream: Int
    public let format: Format
    public let title: String?
    public let language: String?
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let lines: SubtitleLineStream

    public init(
        stream: Int, format: Format, title: String?, language: String?, isForced: Bool, isHearingImpaired: Bool,
        lines: SubtitleLineStream
    ) {
        self.stream = stream
        self.format = format
        self.title = title
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.lines = lines
    }
}

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
    /// The text subtitles stored in the file itself, in file order.
    public let fileSubtitles: [FileSubtitle]
    /// Stops the local media server and releases its SMB reader when the session ends.
    public let cleanup: @Sendable () async -> Void

    public init(
        itemID: ItemID,
        url: URL,
        title: String,
        startTime: CMTime? = nil,
        subtitleURLs: [Int: URL] = [:],
        subtitleLabels: [Int: String] = [:],
        fileSubtitles: [FileSubtitle] = [],
        cleanup: @escaping @Sendable () async -> Void = {}
    ) {
        self.itemID = itemID
        self.url = url
        self.title = title
        self.startTime = startTime
        self.subtitleURLs = subtitleURLs
        self.subtitleLabels = subtitleLabels
        self.fileSubtitles = fileSubtitles
        self.cleanup = cleanup
    }
}
