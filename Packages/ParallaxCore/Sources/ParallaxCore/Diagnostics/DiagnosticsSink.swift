import Darwin
import Foundation
import os

/// Append-only, UNBUFFERED writer for one session's diagnostics file.
///
/// **Why unbuffered.** The whole point of this file is to survive the process that wrote it. A
/// buffered writer (`FileHandle`, `OutputStream`, anything with a userspace staging buffer) loses
/// whatever it hasn't flushed when the process dies — and the interesting lines are always the last
/// ones before the crash. Every record goes straight to the kernel via `write(2)` on an `O_APPEND`
/// descriptor, so the data outlives the process even without an `fsync`: the page cache belongs to
/// the kernel, not to us.
///
/// **Why the descriptor never rotates.** `CrashSentinel` caches this descriptor and writes to it
/// from a signal handler, where re-opening a file (or consulting any Swift state) is not allowed.
/// So a session gets exactly ONE file, opened once and held for the life of the process; size is
/// bounded by a byte cap instead of by rotation, and old SESSIONS are pruned at startup instead.
///
/// **Concurrency.** `@unchecked Sendable` with an explicit lock: the descriptor is immutable after
/// `init`, and the only mutable state (the byte counter and the one-shot "full" latch) sits under an
/// `OSAllocatedUnfairLock`. `write(2)` on an `O_APPEND` descriptor is atomic for the whole record on
/// Darwin, so concurrent writers can't interleave partial lines even between lock releases.
final class DiagnosticsSink: @unchecked Sendable {

    /// The file being appended to. Exposed so the export path can read it back.
    let url: URL

    /// Raw descriptor, also handed to `CrashSentinel`. Never closed — the process holding it is the
    /// only thing that ends the session.
    let descriptor: Int32

    /// Ceiling on ordinary records. Generous for a lifecycle log (this is thousands of lines) and
    /// small enough that five retained sessions can't matter on a tvOS cache volume. A crash report
    /// is written REGARDLESS of this cap — the cap exists to stop a runaway loop from evicting the
    /// crash, not to gate it.
    static let recordByteCap = 512 * 1024

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var bytesWritten = 0
        /// Latched once the cap is hit, so the "log truncated" notice is written exactly once.
        var isFull = false
    }

    /// Opens `url` for append, creating it if needed. Returns nil when the file can't be opened —
    /// diagnostics must never be the reason the app fails to launch.
    init?(url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        self.url = url
        self.descriptor = descriptor
    }

    /// What the cap check decided for one record.
    private enum Admission {
        /// Under the cap — write the record itself.
        case admit
        /// This record crossed the cap. Write the truncation notice in its place, exactly once.
        case truncate
        /// The cap was already announced; drop silently.
        case drop
    }

    /// Appends one already-formatted record (a trailing newline is added here, not by callers).
    /// Silently drops the record once the byte cap is reached.
    func append(_ record: String) {
        let line = record + "\n"
        let byteCount = line.utf8.count

        let admission: Admission = state.withLock { state in
            if state.isFull { return .drop }
            guard state.bytesWritten + byteCount <= Self.recordByteCap else {
                state.isFull = true
                return .truncate
            }
            state.bytesWritten += byteCount
            return .admit
        }

        switch admission {
        case .admit:
            writeRaw(line)
        case .truncate:
            writeRaw("--- log full at \(Self.recordByteCap) bytes; further records dropped, crash reports still recorded ---\n")
        case .drop:
            break
        }
    }

    /// Writes bytes that bypass the cap. Used for the crash preamble the signal handler can't format
    /// itself and for the session header, both of which must never be dropped.
    func appendUncapped(_ record: String) {
        writeRaw(record + "\n")
    }

    private func writeRaw(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            diagnosticsWriteAll(descriptor, base, buffer.count)
        }
    }
}

/// Writes `count` bytes from `bytes` to `descriptor`, retrying short writes and `EINTR`.
///
/// Free function, and deliberately free of allocation, locking and Swift runtime calls: the crash
/// handler in `CrashSentinel` calls this from a signal context where only async-signal-safe work is
/// permitted, and `write(2)` is on that list.
@inline(__always)
func diagnosticsWriteAll(_ descriptor: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) {
    var offset = 0
    while offset < count {
        let written = write(descriptor, bytes + offset, count - offset)
        if written > 0 {
            offset += written
            continue
        }
        // Interrupted by a signal — retry. Anything else (full disk, closed descriptor) is not
        // recoverable here and must not spin.
        if written < 0 && errno == EINTR { continue }
        return
    }
}
