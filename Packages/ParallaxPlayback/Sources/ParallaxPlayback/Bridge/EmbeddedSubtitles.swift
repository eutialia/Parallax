import Foundation
import Synchronization

/// A text subtitle stream stored in a file the bridge delivers.
public struct EmbeddedSubtitle: Sendable, Equatable, Identifiable {
    public enum Format: Sendable, Equatable {
        /// `header` is the script up to its events. A line's content is one event's fields
        /// from `ReadOrder` on, as Matroska stores them.
        case ass(header: Data)
        /// A line's content is its text.
        case srt
    }

    /// The stream's place in the file.
    public let id: Int
    public let format: Format
    public let title: String?
    public let language: String?
    public let isForced: Bool
    public let isHearingImpaired: Bool
}

public struct EmbeddedSubtitleLine: Sendable, Hashable {
    /// In AVPlayer's item time.
    public let start: Duration
    public let duration: Duration
    public let content: Data
}

extension EmbeddedSubtitle {
    /// Nil for a stream that is not a text subtitle the bridge hands over.
    init?(_ stream: DemuxedStream) {
        guard stream.kind == .subtitle else { return nil }
        switch stream.parameters.codecName {
        case "ass", "ssa": format = .ass(header: Data(stream.parameters.configuration))
        case "subrip": format = .srt
        default: return nil
        }
        id = stream.index
        title = stream.title
        language = stream.language
        isForced = stream.isForced
        isHearingImpaired = stream.isHearingImpaired
    }
}

/// The subtitle lines every demuxer of one file has read so far. A segment read passes the
/// lines stored beside its pictures, so they arrive as AVPlayer buffers, each once however
/// often its segment is read.
final class EmbeddedSubtitleLines: Sendable {
    /// A line timed in nanoseconds of the file's own time.
    private struct Stored: Hashable {
        let start: Int64
        let duration: Int64
        let content: Data
    }

    private struct State {
        var lines: [Int: Set<Stored>] = [:]
        var listeners: [Int: [Int: @Sendable ([Stored]?) -> Void]] = [:]
        var nextListener = 0
        var isFinished = false
    }

    private let state = Mutex(State())

    func take(_ packet: MediaPacket) {
        guard let start = packet.presentationTime, let duration = packet.duration else { return }
        let line = Stored(start: start, duration: duration, content: packet.data)
        state.withLock { state in
            guard !state.isFinished, state.lines[packet.stream, default: []].insert(line).inserted else { return }
            state.listeners[packet.stream]?.values.forEach { $0([line]) }
        }
    }

    /// The lines of `stream` read so far, in time order, then each line as it is first read.
    /// `zero` is the time in the file that item time zero falls on. Ends when the delivery stops.
    func lines(of stream: Int, from zero: Int64) -> AsyncStream<[EmbeddedSubtitleLine]> {
        AsyncStream { continuation in
            let listener: @Sendable ([Stored]?) -> Void = { lines in
                guard let lines else { return continuation.finish() }
                continuation.yield(lines.map {
                    EmbeddedSubtitleLine(
                        start: .nanoseconds($0.start - zero), duration: .nanoseconds($0.duration), content: $0.content)
                })
            }
            let id = state.withLock { state -> Int? in
                listener(state.lines[stream, default: []].sorted { $0.start < $1.start })
                guard !state.isFinished else { return nil }
                state.nextListener += 1
                state.listeners[stream, default: [:]][state.nextListener] = listener
                return state.nextListener
            }
            guard let id else { return continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.listeners[stream]?.removeValue(forKey: id) }
            }
        }
    }

    func finish() {
        let listeners = state.withLock { state in
            defer { state.listeners = [:] }
            state.isFinished = true
            return state.listeners.values.flatMap(\.values)
        }
        listeners.forEach { $0(nil) }
    }
}
