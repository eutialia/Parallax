import ParallaxCore

/// How a probed file's bytes reach AVPlayer.
enum DeliveryRoute: Sendable, Equatable {
    /// AVPlayer reads the file's own bytes.
    case direct(Container)
    case unplayable(Unplayable)
}

/// Why AVPlayer cannot play a file the probe did read.
public enum Unplayable: Error, Sendable, Equatable {
    case incompleteFile
    /// Nil when the magic bytes matched no container the probe knows.
    case container(Container?)
    /// Nil when the sample entry is one the probe does not recognize.
    case videoCodec(VideoCodec?)
    case audioCodec(AudioCodec?)
    /// Video in a profile the device does not decode.
    case undecodedProfile(StreamProfile)
    /// An MP4 AVPlayer opens and then misplays.
    case directHazards(Set<AVPlayerHazard>)
    /// A file the bridge opened and cannot deliver.
    case refused(BridgeRefusal)
}

extension Unplayable: CustomStringConvertible {
    /// One line for the player's error details and the log.
    public var description: String {
        switch self {
        case .incompleteFile: "incomplete file"
        case .container(let container): "container: \(container?.rawValue ?? "unknown")"
        case .videoCodec(let codec): "video: \(codec?.rawValue ?? "unknown")"
        case .audioCodec(let codec): "audio: \(codec?.rawValue ?? "unknown")"
        case .undecodedProfile(.h264(let profile)): "video: h264 profile \(profile)"
        case .undecodedProfile(.av1(let profile)): "video: av1 profile \(profile)"
        case .directHazards(let hazards): "hazards: \(hazards.map { "\($0)" }.sorted().joined(separator: ", "))"
        case .refused(let refusal): refusal.description
        }
    }
}

enum DirectPlay {
    static func verdict(for probe: MediaProbeResult, support: AVPlayerSupport) -> DeliveryRoute {
        guard probe.isComplete else { return .unplayable(.incompleteFile) }
        guard let container = probe.container, support.containers.contains(container) else {
            return .unplayable(.container(probe.container))
        }
        switch probe.videoCodec {
        case .unknown: return .unplayable(.videoCodec(nil))
        case .known(let codec) where !support.videoCodecs.contains(codec): return .unplayable(.videoCodec(codec))
        case .known, .none: break
        }
        switch probe.audioCodecs {
        case .unknown: return .unplayable(.audioCodec(nil))
        case .known(let codecs):
            if let missing = codecs.first(where: { !support.audioCodecs.contains($0) }) {
                return .unplayable(.audioCodec(missing))
            }
        case .none: break
        }
        if let profile = probe.videoProfile, !support.decodes(profile) {
            return .unplayable(.undecodedProfile(profile))
        }
        guard probe.avPlayerHazards.isEmpty else { return .unplayable(.directHazards(probe.avPlayerHazards)) }
        return .direct(container)
    }
}

extension AVPlayerSupport {
    /// Whether this device decodes a stream of `profile`. The bridge copies a stream only when
    /// it does, and an MP4 with a stream it does not goes to the bridge.
    func decodes(_ profile: StreamProfile) -> Bool {
        switch profile {
        // Baseline, Main and High are the profiles every Apple decoder takes, and High 10 some.
        case .h264(let profile): [66, 77, 100].contains(profile) || profile == 110 && decodesH264High10
        // Main, where the device has an AV1 decoder at all.
        case .av1(let profile): profile == 0 && videoCodecs.contains(.av1)
        }
    }
}
