import Foundation
import Observation

/// Backs Settings' Storage card: the generated SMB thumbnail cache's on-disk size, and clearing it.
@Observable
@MainActor
public final class ThumbnailCacheModel {
    /// nil until the first size read completes; reset to 0 right after a clear.
    private var byteCount: Int64?
    private var isClearing = false

    private let size: @Sendable () async -> Int64
    private let wipe: @Sendable () async -> Void

    init(size: @escaping @Sendable () async -> Int64, clear: @escaping @Sendable () async -> Void) {
        self.size = size
        self.wipe = clear
    }

    /// The size the card shows, or what it is doing instead.
    public var sizeLabel: String {
        if isClearing { return "Clearing…" }
        guard let byteCount else { return "Calculating…" }
        return byteCount == 0 ? "Empty" : byteCount.formatted(.byteCount(style: .file))
    }

    /// What the card's `.task` runs: reads the cache's size.
    public func measure() async {
        byteCount = await size()
    }

    public func clear() async {
        isClearing = true
        await wipe()
        byteCount = 0
        isClearing = false
    }
}
