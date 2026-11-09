import Foundation
import Observation

/// Backs Settings' Storage card: the generated SMB thumbnail cache's on-disk size, and clearing it.
@Observable
@MainActor
public final class ThumbnailCacheModel {
    private enum State: Equatable {
        case calculating
        case size(Int64)
        case clearing
    }

    private var state = State.calculating
    /// Bumped by every clear, so a size read that started before one can tell it is stale.
    private var clears = 0

    private let size: @Sendable () async -> Int64
    private let wipe: @Sendable () async -> Void

    init(size: @escaping @Sendable () async -> Int64, clear: @escaping @Sendable () async -> Void) {
        self.size = size
        self.wipe = clear
    }

    /// The size the card shows, or what it is doing instead.
    public var sizeLabel: String {
        switch state {
        case .calculating: "Calculating…"
        case .clearing: "Clearing…"
        case .size(0): "Empty"
        case .size(let bytes): bytes.formatted(.byteCount(style: .file))
        }
    }

    /// What the card's `.task` runs: reads the cache's size. A read that a clear overtook is
    /// dropped, since it measured what the clear removed.
    public func measure() async {
        let clearsBefore = clears
        let bytes = await size()
        guard clears == clearsBefore, state != .clearing else { return }
        state = .size(bytes)
    }

    /// A no-op while a clear is already running.
    public func clear() async {
        guard state != .clearing else { return }
        clears += 1
        state = .clearing
        await wipe()
        state = .size(0)
    }
}
