import Foundation

/// Keeps the SHAPE of a browsed path in the log while dropping its CONTENT.
///
/// **Why this exists.** The retained log is written to be shared — the tvOS handoff serves it over
/// the LAN and the iOS export hands it to a share sheet — so it should not carry what somebody
/// watches. A raw listing record does exactly that: a folder name like
/// `[Group] Some Series [01-13][WebRip 1080p]` is a viewing history one line at a time.
///
/// What survives is what diagnosis actually needs: the host, the share, how DEEP the path was, and a
/// token that is equal for equal paths. Every question this log has had to answer — which share
/// stalled, whether two records are the same folder, how many levels down a failure was — is
/// answerable from those. None of them need the names.
///
/// **The salt is per process, on purpose.** A bare hash of a folder name is reversible by anyone
/// willing to hash a list of candidate titles, which is not a high bar for media. Re-salting each
/// launch keeps digests comparable within one session — the only place correlation is ever wanted —
/// and worthless to anyone comparing across sessions or against a precomputed table.
public enum DiagnosticsRedaction {

    /// Randomised per launch. Not for secrecy of the salt itself (it never leaves the process); it
    /// exists so the digests in one exported file cannot be matched against another file or a
    /// dictionary.
    private static let salt = UInt64.random(in: UInt64.min...UInt64.max)

    /// A share-relative path reduced to depth plus a stable token.
    ///
    /// Paths that carry nothing to hide come back untouched, so a share root still reads as a share
    /// root rather than as a redaction: `""` and `"/"` are returned as-is.
    public static func path(_ path: String) -> String {
        // Both separators, because an SMB path can arrive in either form depending on who built it.
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.isEmpty else { return path }
        return "/…\(components.count)#\(digest(path))"
    }

    /// Four hex characters of a salted FNV-1a. Short because it is read by eye in a dense log and
    /// only ever has to distinguish the handful of paths one session touches — not to be
    /// collision-proof, which it does not need to be and could not cheaply be.
    static func digest(_ value: String) -> String {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        // Salt bytes folded in by shifting rather than through an `Array`, and `value.utf8` consumed
        // in place: this runs on every listing record, so it should not allocate at all.
        for shift in stride(from: 0, to: 64, by: 8) {
            hash ^= (salt >> UInt64(shift)) & 0xff
            hash &*= prime
        }
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%04x", UInt16(truncatingIfNeeded: hash))
    }
}
