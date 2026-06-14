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

/// The minimal SMB surface the repository needs. AMSMB2 hides behind the concrete impl;
/// tests use FakeSMBLister. Top-level listing only — no recursion (per the browse model).
public protocol SMBLister: Sendable {
    func list(share: String, path: String) async throws -> [SMBDirectoryEntry]
    func disconnect() async
}
