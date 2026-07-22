import CryptoKit
import Foundation

extension Data {
    /// Lowercase hex SHA-256 digest of these bytes — the shared key-hashing primitive behind
    /// the SMB thumbnail cache's file base names and the connection pool's credential digest.
    /// Identity derivation only, never secrets-at-rest: callers hash paths (stable filenames)
    /// and passwords (so a raw secret never enters a pool key or a log that prints one).
    public var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
