import AMSMB2
import Foundation

/// Real `SMBLister` over AMSMB2 (libsmb2 SMB2/3). Directory enumeration only —
/// streaming runs through libVLC's native `smb://` path, not this type.
///
/// Concurrency: an `actor`. `SMB2Manager` is a stateful connection (one
/// `connectShare` at a time), so serialising every `list`/`disconnect` through
/// the actor keeps the share-connect lifecycle race-free. The manager is lazily
/// (re)connected per share on first use and torn down on `disconnect()`.
///
/// Credentials: built once into a `URLCredential` from username/password/domain
/// supplied by the caller (the password comes from Keychain at the call site).
/// They live only inside the `URLCredential` handed to `SMB2Manager` — never
/// logged, never embedded in a URL string. The `host` URL we construct carries
/// no userinfo.
public actor AMSMB2Lister: SMBLister {

    private let serverURL: URL
    private let domain: String
    private let credential: URLCredential

    /// The live manager + the share it is currently connected to. Both are reset
    /// by `disconnect()` and rebuilt on the next `list` against a (possibly new) share.
    private var manager: SMB2Manager?
    private var connectedShare: String?

    /// - Parameters:
    ///   - host: bare SMB host, e.g. `"192.168.1.10"` (no scheme, no userinfo).
    ///   - username: account user.
    ///   - password: account password — supplied by the caller (Keychain at the call site).
    ///     Never logged, never placed in a URL.
    ///   - domain: SMB/NT domain or workgroup (e.g. `"WORKGROUP"`). Empty is allowed.
    public init(host: String, username: String, password: String, domain: String = "") {
        // Scheme-only URL; AMSMB2 derives the connection target from it. No credentials here.
        self.serverURL = URL(string: "smb://\(host)") ?? URL(string: "smb://invalid")!
        self.domain = domain
        // The NT domain/workgroup is passed to AMSMB2's dedicated `domain:` init
        // parameter — NOT folded into the user field. In libsmb2, a `DOMAIN\user`
        // user string maps to the NTLM *workstation* field, not the domain
        // (verified against AMSMB2 4.0.3 source), so folding it there is wrong.
        self.credential = URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// Lists one directory level of `share` at `path`. Connects (or reconnects to a
    /// different share) on demand, then maps each AMSMB2 attribute dictionary to a
    /// neutral `SMBDirectoryEntry`. Non-recursive.
    public func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        let client = try await connectedManager(for: share)
        let listPath = path.isEmpty ? "/" : path
        let raw = try await client.contentsOfDirectory(atPath: listPath, recursive: false)
        return raw.map { attrs in
            SMBDirectoryEntry(
                name: attrs.name ?? "",
                isDirectory: attrs.isDirectory,
                size: attrs.fileSize ?? 0,
                modifiedAt: attrs.contentModificationDate
            )
        }
    }

    /// Disconnects the active share (if any) and drops the manager.
    public func disconnect() async {
        let client = manager
        manager = nil
        connectedShare = nil
        guard let client else { return }
        // AMSMB2's disconnect can throw; a teardown failure is not actionable here.
        try? await client.disconnectShare()
    }

    // MARK: - Connection

    private func connectedManager(for share: String) async throws -> SMB2Manager {
        if let manager, connectedShare == share {
            return manager
        }
        // Switching shares (or first connect): tear down the old connection first.
        if let manager, connectedShare != share {
            try? await manager.disconnectShare()
            self.manager = nil
            self.connectedShare = nil
        }
        guard let client = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
            throw SMBListerError.managerInitFailed
        }
        try await client.connectShare(name: share)
        self.manager = client
        self.connectedShare = share
        return client
    }
}

/// Errors surfaced by `AMSMB2Lister`. Carries no credential material.
public enum SMBListerError: Error, Sendable {
    /// `SMB2Manager(url:domain:credential:)` returned nil (malformed host URL).
    case managerInitFailed
}
