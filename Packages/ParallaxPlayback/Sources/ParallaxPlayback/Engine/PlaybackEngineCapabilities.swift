import Foundation

public struct PlaybackEngineCapabilities: Sendable, Hashable {
    public let supportsPiP: Bool
    public let supportsVideoAirPlay: Bool
    public let supportsAudioAirPlay: Bool
    public let supportsNowPlayingIntegration: Bool

    public init(
        supportsPiP: Bool,
        supportsVideoAirPlay: Bool,
        supportsAudioAirPlay: Bool,
        supportsNowPlayingIntegration: Bool
    ) {
        self.supportsPiP = supportsPiP
        self.supportsVideoAirPlay = supportsVideoAirPlay
        self.supportsAudioAirPlay = supportsAudioAirPlay
        self.supportsNowPlayingIntegration = supportsNowPlayingIntegration
    }
}
