import AMSMB2
import Foundation
import OSLog
import ParallaxCore

/// `RandomAccessReading` over AMSMB2 (libsmb2 SMB2/3), for container probing and the
/// localhost HTTP bridge that feeds AVPlayer. Logic-free glue: it maps `read`/`fileSize`
/// onto a single lazily-connected `SMB2Manager`, mirroring `AMSMB2Lister`'s connection,
/// credential, and fast-fail-timeout pattern.
///
/// Concurrency: an `actor`. `SMB2Manager` is a stateful single-share connection, so
/// serialising every `read`/`fileSize`/`disconnect` through the actor keeps the connect
/// lifecycle race-free. The manager is connected once (to `share`) on first use and torn
/// down on `disconnect()`.
///
/// Credentials: built once into a `URLCredential` from username/password/domain supplied
/// by the caller (the password comes from Keychain at the call site). They live only inside
/// the `URLCredential` handed to `SMB2Manager` — never logged, never embedded in a URL. The
/// `host` URL we construct carries no userinfo. The file `path` may be logged (matches the
/// `SMBFileSource.mapListError` precedent).
public actor SMBRandomAccessReader: RandomAccessReading {

    private static let logger = Logger(subsystem: "Parallax", category: "SMBRandomAccessReader")

    private let serverURL: URL
    private let domain: String
    private let credential: URLCredential
    private let share: String
    private let path: String

    /// Per-operation response timeout. AMSMB2 defaults to 60s, which on an unreachable or
    /// wrong host turns `connectShare`/`contents` into a full-minute hang. A short
    /// LAN-appropriate ceiling fails fast instead (see `AMSMB2Lister`).
    private let connectTimeout: TimeInterval

    /// The live manager, lazily connected to `share`. Reset by `disconnect()`.
    private var manager: SMB2Manager?

    /// File size, cached after the first successful `attributesOfItem`. The bridge and probe
    /// treat the first read as authoritative — a mid-walk grow must not shift the size out
    /// from under an in-flight `Content-Range`.
    private var cachedFileSize: UInt64?

    /// - Parameters:
    ///   - host: bare SMB host, e.g. `"192.168.1.10"` (no scheme, no userinfo).
    ///   - username: account user.
    ///   - password: account password — supplied by the caller (Keychain at the call site).
    ///     Never logged, never placed in a URL.
    ///   - domain: SMB/NT domain or workgroup (e.g. `"WORKGROUP"`). Empty is allowed.
    ///   - share: the share to connect (e.g. `"Media"`).
    ///   - path: share-relative file path (e.g. `"Movies/film.mp4"`).
    ///   - connectTimeout: per-operation response ceiling (default 15s). Bounds connect/read so
    ///     a dead host fails fast instead of hanging on AMSMB2's 60s default.
    public init(host: String, username: String, password: String, domain: String = "",
                share: String, path: String, connectTimeout: TimeInterval = 15) {
        // Scheme-only URL; AMSMB2 derives the connection target from it. No credentials here.
        // Percent-encode the host so a Bonjour-synthesised name with a space (e.g.
        // "My NAS.local") forms a real URL and attempts a resolve, instead of silently
        // collapsing to the bogus "smb://invalid" fallback.
        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        self.serverURL = URL(string: "smb://\(encodedHost)") ?? URL(string: "smb://invalid")!
        self.domain = domain
        // The NT domain/workgroup is passed to AMSMB2's dedicated `domain:` init parameter —
        // NOT folded into the user field. In libsmb2, a `DOMAIN\user` user string maps to the
        // NTLM *workstation* field, not the domain (verified against AMSMB2 4.0.3 source), so
        // folding it there is wrong.
        self.credential = URLCredential(user: username, password: password, persistence: .forSession)
        self.share = share
        self.path = path
        self.connectTimeout = connectTimeout
    }

    /// Total size in bytes, cached after the first success.
    public var fileSize: UInt64 {
        get async throws {
            if let cachedFileSize { return cachedFileSize }
            let client = try await connectedManager()
            let attributes = try await client.attributesOfItem(atPath: path)
            let size = UInt64(max(0, attributes.fileSize ?? 0))
            cachedFileSize = size
            return size
        }
    }

    /// Reads up to `length` bytes at `offset`. Honors the POSIX-pread contract: a read at or
    /// past EOF returns the available prefix (possibly empty). AMSMB2's `contents(atPath:range:)`
    /// already implements this — an out-of-range lowerBound yields empty `Data`, and an
    /// over-long range truncates to the remaining file content — so no manual clamping is needed.
    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let client = try await connectedManager()
        let upperBound = offset.addingReportingOverflow(UInt64(length)).partialValue
        do {
            return try await client.contents(atPath: path, range: offset..<upperBound)
        } catch let error as POSIXError where error.code == .ENODATA || error.code == .ERANGE {
            // Defensive: if a future AMSMB2 surfaced an EOF-shaped POSIX error instead of a
            // short read, honor the pread contract by returning the empty prefix.
            return Data()
        }
    }

    /// Disconnects the active share (if any) and drops the manager. Idempotent.
    public func disconnect() async {
        let client = manager
        manager = nil
        guard let client else { return }
        // AMSMB2's disconnect can throw; a teardown failure is not actionable here.
        try? await client.disconnectShare()
    }

    // MARK: - Connection

    /// Returns the live manager, connecting to `share` on first use. ASSUMES a single caller
    /// per instance: `await client.connectShare` below is a suspension point *before*
    /// `self.manager` is set, so two CONCURRENT first reads would open two connections (actor
    /// reentrancy). The HTTP bridge fronts this reader from many connections, but it always
    /// probes/starts via one `fileSize`/`read` before serving, and AMSMB2 itself serialises;
    /// if concurrent cold-start ever becomes real, memoize an in-flight connect `Task` here.
    private func connectedManager() async throws -> SMB2Manager {
        if let manager { return manager }
        guard let client = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
            throw SMBListerError.managerInitFailed
        }
        // Bound every operation so a dead/wrong host fails in `connectTimeout` seconds instead of
        // AMSMB2's 60s default.
        client.timeout = connectTimeout
        try await client.connectShare(name: share)
        manager = client
        return client
    }
}
