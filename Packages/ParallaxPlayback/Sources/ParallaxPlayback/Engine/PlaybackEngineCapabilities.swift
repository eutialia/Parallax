import Foundation

/// What a concrete `PlaybackEngine` supports, so the app can show or hide PiP, AirPlay,
/// and Now Playing affordances without knowing which engine is active.
public struct PlaybackEngineCapabilities: Sendable, Hashable {
    /// Picture-in-Picture is available.
    public let supportsPiP: Bool
    /// Video (not just audio) can be sent to an AirPlay receiver.
    public let supportsVideoAirPlay: Bool
    /// Audio can be routed to an AirPlay receiver.
    public let supportsAudioAirPlay: Bool
    /// The engine drives the system Now Playing info and remote command center.
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
