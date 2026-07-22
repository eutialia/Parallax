import AMSMB2
import Foundation
import os
import ParallaxCore

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
    private static let logger = Log.custom(category: "AMSMB2Lister")

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
        // The Bonjour-space percent-encoding subtlety lives in SMBURL.hostOnly, shared with
        // the connection pool's SMBConnectionTarget.
        self.serverURL = SMBURL.hostOnly(host)
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
        Self.logger.debug("listShares: creating manager for \(self.serverURL.host() ?? "?", privacy: .public)")
        guard let client = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
            throw SMBListerError.managerInitFailed
        }
        client.timeout = connectTimeout
        Self.logger.debug("listShares: entering bounded enumeration")
        do {
            let raw = try await bounded { try await client.listShares(enumerateHidden: false) }
            Self.logger.debug("listShares: enumerated \(raw.count) shares")
            return raw.map { SMBShare(name: $0.name, comment: $0.comment) }
        } catch {
            Self.logger.debug("listShares: threw \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Lists one directory level of `share` at `path`. Connects (or reconnects to a
    /// different share) on demand, then maps each AMSMB2 attribute dictionary to a
    /// neutral `SMBDirectoryEntry`. Non-recursive.
    public func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        let client = try await connectedManager(for: share)
        let listPath = path.isEmpty ? "/" : path
        // Mapped INSIDE the bound: AMSMB2's raw attribute dictionaries are `[URLResourceKey: Any]`
        // (not Sendable), so only the neutral entries may cross the race boundary.
        return try await bounded {
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
        try await bounded { try await client.connectShare(name: share) }
        self.manager = client
        self.connectedShare = share
        return client
    }

    /// Outer wall-clock ceiling on one AMSMB2 operation. AMSMB2's own `timeout` bounds SMB PDU
    /// responses but NOT every connect phase — on device, name resolution can block far past it
    /// (the tvOS add-server "spinner forever" hang) — so every await on the manager goes through
    /// this bound too. The grace over `connectTimeout` lets AMSMB2's more specific error win
    /// whenever its own timeout does fire; this ceiling only bites in the phases AMSMB2 never
    /// bounds. See `withHardTimeout` for why the loser keeps running detached.
    private func bounded<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withHardTimeout(seconds: connectTimeout + 5, operation: operation)
        } catch is HardTimeoutError {
            // The abandoned C call is still running on this connection and its state is now
            // unknown — never reuse it. Drop the manager so the next call builds a fresh
            // connection instead of racing the orphan (no disconnect attempt: that would await
            // the same wedged connection).
            manager = nil
            connectedShare = nil
            throw SMBListerError.timedOut
        }
    }
}

/// Errors surfaced by `AMSMB2Lister`. Carries no credential material.
public enum SMBListerError: Error, Sendable {
    /// `SMB2Manager(url:domain:credential:)` returned nil (malformed host URL).
    case managerInitFailed
    /// The operation outlived the hard wall-clock ceiling (`connectTimeout` + grace) — an
    /// unreachable host hanging in a phase AMSMB2's own response timeout doesn't cover.
    case timedOut
}
