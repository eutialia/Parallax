import Foundation

/// A single entry returned by an SMB directory listing.
public struct SMBDirectoryEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    /// Last content-write time (SMB `mtime`). nil when the server omits it.
    public let modifiedAt: Date?
    /// Birth time (SMB `btime` / `creationDate`). nil when the server omits it — not every SMB
    /// server fills it, so the date-sort comparator treats a missing value as unknown (sorts last).
    public let createdAt: Date?

    public init(name: String, isDirectory: Bool, size: Int64, modifiedAt: Date?, createdAt: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}

/// One SMB share advertised by a server (name + optional comment/remark).
public struct SMBShare: Sendable, Hashable {
    public let name: String
    public let comment: String
    public init(name: String, comment: String) {
        self.name = name
        self.comment = comment
    }
}

/// The minimal SMB surface the repository needs. AMSMB2 hides behind the concrete impl
/// (`PooledSMBLister`); tests use FakeSMBLister. Top-level listing only — no recursion (per the
/// browse model).
///
/// There is deliberately no `disconnect()`: the lifetime of a POOLED share connection belongs to
/// `SMBConnectionPool`, the only thing that may tear one down and only once nothing is using it.
/// A lister-owned disconnect is what let a directory listing on a wedged socket be freed under its
/// own pending call. Share enumeration is the one documented exception — it has no share to pool,
/// so `PooledSMBLister.listShares` owns a one-shot connection and tears it down itself, always
/// gracefully (see that method for why).
public protocol SMBLister: Sendable {
    /// Server-level share enumeration (IPC$ + srvsvc). No share connection required.
    func listShares() async throws -> [SMBShare]
    func list(share: String, path: String) async throws -> [SMBDirectoryEntry]
}

/// The account one lister signs in with.
///
/// A value type rather than four loose `String`s because the app passes these across a closure
/// boundary (`AppDependencies.makeSMBLister`), and Swift function types cannot carry argument
/// labels: three interchangeable strings in a row is a silent-transposition trap, and a swapped
/// password/domain compiles cleanly then fails as a sign-in refusal that reads like the server's
/// fault. The password lives only here and in the `URLCredential` handed to the SMB client —
/// never logged, never placed in a URL, and folded into the pool key only as a digest.
public struct SMBCredentials: Sendable {
    /// Bare SMB host, e.g. `"192.168.1.10"` (no scheme, no userinfo).
    public let host: String
    public let username: String
    public let password: String
    /// SMB/NT domain or workgroup (e.g. `"WORKGROUP"`). Empty is allowed.
    public let domain: String

    public init(host: String, username: String, password: String, domain: String = "") {
        self.host = host
        self.username = username
        self.password = password
        self.domain = domain
    }
}

/// Errors surfaced by the SMB listing/pooling layer. Carries no credential material.
public enum SMBListerError: Error, Sendable, Equatable {
    /// `SMB2Manager(url:domain:credential:)` returned nil (malformed host URL).
    case managerInitFailed
    /// The operation outlived the hard wall-clock ceiling (`connectTimeout` + grace) — an
    /// unreachable host hanging in a phase AMSMB2's own response timeout doesn't cover.
    case timedOut
}
