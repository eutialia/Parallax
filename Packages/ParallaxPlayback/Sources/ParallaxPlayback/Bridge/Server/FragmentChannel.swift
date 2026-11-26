import Foundation
import Synchronization

/// Carries one segment's fragments from the demuxer's queue, where they are made, to the
/// connection that sends them. It holds one fragment: `put` blocks until the one before is
/// taken, so a read runs at most a fragment ahead of its client, whatever the client's pace.
final class FragmentChannel: BodyProducer, @unchecked Sendable {
    private let cancelled = Atomic(false)
    private let fetched = Atomic(0)
    /// Told each change in the bytes the channel holds: the fragment waiting in it and the one
    /// the server took last, which it is sending until it asks for the next.
    private let heldChanged: @Sendable (Int) -> Void
    /// Guards everything below. A blocked `put` releases it while it waits.
    private let condition = NSCondition()
    private var slot: Data?
    private var sending = 0
    private var end: Result<Void, any Error>?
    private var taker: CheckedContinuation<Data?, any Error>?

    init(heldChanged: @escaping @Sendable (Int) -> Void) {
        self.heldChanged = heldChanged
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    var bytesFetched: Int { fetched.load(ordering: .relaxed) }

    /// What the segment's read has fetched from the source so far.
    func setBytesFetched(_ bytes: Int) {
        fetched.store(bytes, ordering: .relaxed)
    }

    /// Blocks while the channel is full. Throws `CancellationError` once the channel is
    /// cancelled, waiting or not.
    func put(_ fragment: Data) throws {
        condition.lock()
        while slot != nil, !isCancelled { condition.wait() }
        guard !isCancelled else {
            condition.unlock()
            throw CancellationError()
        }
        let waiting = taker
        taker = nil
        if waiting == nil {
            slot = fragment
        } else {
            sending = fragment.count
        }
        heldChanged(fragment.count)
        condition.unlock()
        waiting?.resume(returning: fragment)
    }

    /// After the last `put`: success, or what stopped the segment.
    func finish(_ result: Result<Void, any Error>) {
        condition.lock()
        end = result
        if result.isFailure { release(slot: true) }
        let waiting = slot == nil ? taker : nil
        if waiting != nil { taker = nil }
        condition.unlock()
        waiting?.resume(with: result.map { nil })
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            release(slot: false)
            if isCancelled {
                condition.unlock()
                continuation.resume(throwing: CancellationError())
            } else if let fragment = slot {
                slot = nil
                sending = fragment.count
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: fragment)
            } else if let end {
                condition.unlock()
                continuation.resume(with: end.map { nil })
            } else {
                taker = continuation
                condition.unlock()
            }
        }
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        let waiting = taker
        taker = nil
        release(slot: true)
        condition.broadcast()
        condition.unlock()
        waiting?.resume(throwing: CancellationError())
    }

    /// Under the lock: the fragment the server was sending is sent, and with `slot`, the one
    /// waiting is dropped.
    private func release(slot dropsSlot: Bool) {
        let dropped = dropsSlot ? slot?.count ?? 0 : 0
        if dropsSlot { slot = nil }
        if sending + dropped > 0 { heldChanged(-(sending + dropped)) }
        sending = 0
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}
