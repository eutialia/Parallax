import Foundation

/// A single entry returned by an SMB directory listing.
public struct SMBDirectoryEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?

    public init(name: String, isDirectory: Bool, size: Int64, modifiedAt: Date?) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
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

/// The minimal SMB surface the repository needs. AMSMB2 hides behind the concrete impl;
/// tests use FakeSMBLister. Top-level listing only — no recursion (per the browse model).
public protocol SMBLister: Sendable {
    /// Server-level share enumeration (IPC$ + srvsvc). No share connection required.
    func listShares() async throws -> [SMBShare]
    func list(share: String, path: String) async throws -> [SMBDirectoryEntry]
    func disconnect() async
}
