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

    /// Per-operation response timeout. AMSMB2 defaults to 60s, which on an unreachable or
    /// wrong host turns `connectShare`/`list` into a full-minute hang with no feedback — the
    /// SMB-login "spins forever" bug. A short LAN-appropriate ceiling fails fast instead; the
    /// SMB handshake and a single non-recursive directory level both complete in well under a
    /// second on a reachable share, so this only ever bites a dead host.
    private let connectTimeout: TimeInterval

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
    ///   - connectTimeout: per-operation response ceiling (default 15s). Bounds the connect/list
    ///     so a dead host fails fast instead of hanging on AMSMB2's 60s default.
    public init(host: String, username: String, password: String, domain: String = "", connectTimeout: TimeInterval = 15) {
        // Scheme-only URL; AMSMB2 derives the connection target from it. No credentials here.
        // Percent-encode the host so a Bonjour-synthesised name with a space (e.g.
        // "My NAS.local") forms a real URL and attempts a resolve, instead of silently
        // collapsing to the bogus "smb://invalid" fallback.
        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        self.serverURL = URL(string: "smb://\(encodedHost)") ?? URL(string: "smb://invalid")!
        self.domain = domain
        // The NT domain/workgroup is passed to AMSMB2's dedicated `domain:` init
        // parameter — NOT folded into the user field. In libsmb2, a `DOMAIN\user`
        // user string maps to the NTLM *workstation* field, not the domain
        // (verified against AMSMB2 4.0.3 source), so folding it there is wrong.
        self.credential = URLCredential(user: username, password: password, persistence: .forSession)
        self.connectTimeout = connectTimeout
    }

    /// Enumerates the server's shares via AMSMB2 (connects to IPC$ + srvsvc internally).
    /// `enumerateHidden: false` excludes `$`-admin shares. Server-level: does not retain
    /// the manager as the per-share connection.
    public func listShares() async throws -> [SMBShare] {
        guard let client = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
            throw SMBListerError.managerInitFailed
        }
        client.timeout = connectTimeout
        let raw = try await client.listShares(enumerateHidden: false)
        return raw.map { SMBShare(name: $0.name, comment: $0.comment) }
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
                modifiedAt: attrs.contentModificationDate,
                createdAt: attrs.creationDate
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

    /// Returns the live manager for `share`, connecting on demand. ASSUMES a single caller per
    /// instance: `await client.connectShare` below is a suspension point *before* `self.manager`
    /// is set, so two CONCURRENT `list()` calls for the same not-yet-connected share would open
    /// two connections (actor reentrancy). Safe today because every lister is single-use — one
    /// `items()` per grid, and `SMBSubtitleResolver` builds its own — so no instance ever sees
    /// concurrent `list()`. Keep it that way, or memoize an in-flight connect `Task` here.
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
        // Bound every operation so a dead/wrong host fails in `connectTimeout` seconds instead of
        // AMSMB2's 60s default (the SMB-login spin-forever bug).
        client.timeout = connectTimeout
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
