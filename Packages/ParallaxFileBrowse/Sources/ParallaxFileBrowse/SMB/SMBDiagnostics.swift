import Foundation
import os
import ParallaxCore

/// The SMB layer's retained-log channels, in one place so the category strings can't drift apart
/// across the four files that write to them.
///
/// **What gets recorded here, and why only this.** The SMB stack's worst failures are native ones —
/// libsmb2 dispatching a callback onto a context somebody else already destroyed — and they happen
/// when a device wakes from sleep with every socket dead and no debugger anywhere near it. A stack
/// alone doesn't explain those; what explains them is knowing which native call was IN FLIGHT and
/// which connection was being torn down at the same moment. So every AMSMB2 call that can hang or
/// crash is bracketed `→` on entry and `←` on return, and every teardown decision (check in, discard,
/// condemn, release) says what it decided. A crash then shows as a `→` with no matching `←`.
///
/// Reads are deliberately NOT bracketed: a scrolling wall issues thousands, and they would push the
/// lifecycle records past the file's byte cap — which is exactly the evidence this exists to keep.
enum SMBDiagnostics {

    /// Borrow lifecycle: checkout, check-in, eviction, flush, reap.
    static let pool = Log.retained(category: "SMBPool")

    /// Parking and release of connections with a pending native call — including the FUSED release,
    /// the one path that lets go of a connection libsmb2 may still hold a request for.
    static let graveyard = Log.retained(category: "SMBGraveyard")

    /// Directory and share enumeration, bracketed around the native call.
    static let lister = Log.retained(category: "SMBLister")

    /// A short, stable tag for one connection object, so a teardown record can be matched to the
    /// borrow that produced it. Low 24 bits of the object's address — unique enough within a
    /// session, short enough not to dominate a line.
    static func tag(_ object: AnyObject) -> String {
        let address = UInt(bitPattern: ObjectIdentifier(object))
        return String(address & 0xFF_FFFF, radix: 16)
    }

    /// How many `disconnectShare(gracefully:)` calls are in flight right now.
    ///
    /// **What this is for.** The app is being killed by the scene-update watchdog — a wall-clock
    /// deadline, with the process at 0% CPU — right after a foreground flush fires several graceful
    /// disconnects at once. A graceful disconnect waits for AMSMB2's operation queue to drain, and
    /// each one is started as `Task { … }`, i.e. on the Swift concurrency COOPERATIVE POOL, which is
    /// only as wide as the core count. If those waits block rather than suspend, a few of them take
    /// the whole pool down and nothing else in the process can run — which is exactly what an idle
    /// main thread at 0% CPU missing a deadline looks like.
    ///
    /// Stamping the live count into both the `→` and `←` records makes that testable from the log
    /// alone: `→` records that pile up with no matching `←` name the calls that never returned, and
    /// the peak count says how much of the pool they were holding.
    private static let inFlightDisconnects = OSAllocatedUnfairLock(initialState: 0)

    static func beginDisconnect() -> Int {
        inFlightDisconnects.withLock { count in
            count += 1
            return count
        }
    }

    static func endDisconnect() -> Int {
        inFlightDisconnects.withLock { count in
            count = max(0, count - 1)
            return count
        }
    }
}
