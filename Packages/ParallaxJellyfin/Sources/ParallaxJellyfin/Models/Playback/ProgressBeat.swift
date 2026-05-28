import Foundation

/// One progress sample the app's view model hands to PlaybackInfoService.
/// `positionTicks` is `seconds * 10_000_000` (Jellyfin's 100-nanosecond
/// tick unit). `itemID` is needed because the report bodies carry ItemId.
public struct ProgressBeat: Sendable, Hashable {
    public let positionTicks: Int
    public let isPaused: Bool
    public let method: PlaybackMethod
    public let itemID: String
    public let mediaSourceID: String
    public let playSessionID: String

    public init(
        positionTicks: Int,
        isPaused: Bool,
        method: PlaybackMethod,
        itemID: String,
        mediaSourceID: String,
        playSessionID: String
    ) {
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.method = method
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
    }
}
