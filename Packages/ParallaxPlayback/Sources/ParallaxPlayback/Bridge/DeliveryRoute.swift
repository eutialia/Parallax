import ParallaxCore

/// How a probed file's bytes reach AVPlayer.
public enum DeliveryRoute: Sendable, Equatable {
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
        case .directHazards(let hazards): "hazards: \(hazards.map { "\($0)" }.sorted().joined(separator: ", "))"
        case .refused(let refusal): refusal.description
        }
    }
}

public enum DirectPlay {
    public static func verdict(for probe: MediaProbeResult, support: AVPlayerSupport) -> DeliveryRoute {
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
        guard probe.avPlayerHazards.isEmpty else { return .unplayable(.directHazards(probe.avPlayerHazards)) }
        return .direct(container)
    }
}
