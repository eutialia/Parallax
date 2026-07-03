import Foundation

/// What a concrete `PlaybackEngine` supports, so the app can show or hide PiP, AirPlay,
/// and Now Playing affordances without knowing which engine is active.
public struct PlaybackEngineCapabilities: Sendable, Hashable {
    /// Picture-in-Picture is available.
    public let supportsPiP: Bool
    /// Video (not just audio) can be sent to an AirPlay receiver.
    public let supportsVideoAirPlay: Bool
    /// The engine drives the system Now Playing info and remote command center.
    public let supportsNowPlayingIntegration: Bool

    public init(
        supportsPiP: Bool,
        supportsVideoAirPlay: Bool,
        supportsNowPlayingIntegration: Bool
    ) {
        self.supportsPiP = supportsPiP
        self.supportsVideoAirPlay = supportsVideoAirPlay
        self.supportsNowPlayingIntegration = supportsNowPlayingIntegration
    }
}
