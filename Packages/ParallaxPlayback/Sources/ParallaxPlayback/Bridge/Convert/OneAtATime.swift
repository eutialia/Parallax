import Synchronization

/// Runs one piece of work at a time. The rest wait, and run in the order they asked.
final class OneAtATime: Sendable {
    private let state = Mutex((isRunning: false, waiting: [CheckedContinuation<Void, Never>]()))

    func run<Value>(_ work: () async throws -> Value) async rethrows -> Value {
        await withCheckedContinuation { continuation in
            let isFree = state.withLock { state in
                if state.isRunning { state.waiting.append(continuation) }
                defer { state.isRunning = true }
                return !state.isRunning
            }
            if isFree { continuation.resume() }
        }
        defer {
            // The turn passes straight to the next in line, so `isRunning` stays true.
            let next = state.withLock { state in
                if state.waiting.isEmpty { state.isRunning = false }
                return state.waiting.isEmpty ? nil : state.waiting.removeFirst()
            }
            next?.resume()
        }
        return try await work()
    }
}
