import AMSMB2
import Foundation

/// `SMBLister` over the shared `SMBConnectionPool` — directory enumeration and share enumeration.
/// Streaming runs through libVLC's native `smb://` path or the HTTP bridge, not this type.
///
/// **Why it is pooled.** Browsing used to stand up a fresh `SMB2Manager` per screen and tear it
/// down again on disappear, so every drill-in and every back-navigation paid a full SMB handshake
/// (4–6 round trips). Borrowing from the same pool the readers use means a browse-then-play flow
/// reuses one authenticated share connection end to end.
///
/// **Why it fixes a crash.** The old per-screen lister disconnected its manager from the view's
/// `onDisappear`. Dropping the last reference to a manager that still has a native call pending —
/// a directory listing on a socket wedged by device sleep — let libsmb2 destroy its context under
/// that call and fire the completion against freed memory. The pool never disconnects a connection
/// while anyone holds it, so no borrow here can be released mid-call. The rules this type must keep:
///  - a completed listing CHECKS IN (the borrow is warm and reusable);
///  - a listing that FINISHED with an error DISCARDS (the socket may be half-consumed; the next
///    borrower must not get it) — a graceful teardown with nothing left pending to race;
///  - a listing still RUNNING when we give up on it — the hard ceiling fired, or the caller was
///    cancelled — is CONDEMNED: parked alive, never disconnected, never released until its native
///    call returns. Disconnecting one of those is itself a crash, `gracefully:` or not; the law and
///    the leak it deliberately accepts are on `SMBConnectionGraveyard`.
///
/// **Share enumeration does not use the pool.** `listShares` has no share to connect to — it is how
/// the shares are discovered in the first place — and AMSMB2 runs it over its own IPC$ connection,
/// replacing whatever share connection the manager held. So it builds a one-shot server-level
/// connection, uses it, and tears it down; pooling it would burn a warm share connection per call
/// and hand back a manager whose share was silently swapped.
///
/// **Credentials** ride as one `SMBCredentials` value, packed into an `SMBConnectionTarget` per call
/// (which derives the pool key from a password DIGEST, never the raw secret) and reaching
/// `SMB2Manager` only as a `URLCredential` — never logged, never embedded in a URL.
///
/// Generic over `SMBListableConnection` for the same reason the pool and the reader are generic:
/// production instantiates it with `SMB2Manager` (inferred from the pool argument), and tests inject
/// a fake so the borrow/discard lifecycle is exercised without a share.
public struct PooledSMBLister<Connection: SMBListableConnection>: SMBLister {

    private let pool: SMBConnectionPool<Connection>
    private let credentials: SMBCredentials

    /// Per-operation response ceiling pinned on each borrow. AMSMB2 defaults to 60s, which on an
    /// unreachable host turns a listing into a full-minute hang with no feedback. A short
    /// LAN-appropriate ceiling fails fast instead — a single non-recursive directory level completes
    /// in well under a second on a reachable share, so this only ever bites a dead host.
    private let connectTimeout: TimeInterval

    /// Builds a server-level connection (no share attached) for `listShares`. Injected so tests can
    /// drive share enumeration without a network; production supplies the `SMB2Manager` version via
    /// the convenience `init` below. Same make-then-deliver contract as the pool's connector — see
    /// `SMBConnectionBuilder`.
    private let connectServer: SMBConnectionBuilder<Connection>

    /// - Parameters:
    ///   - pool: the shared connection pool to borrow share connections from.
    ///   - credentials: host + account to sign in with. The password is supplied by the caller
    ///     (Keychain at the call site), never logged, never placed in a URL, and folded into the
    ///     pool key only as a SHA256 digest.
    ///   - connectTimeout: per-operation ceiling on a borrowed connection (the pool owns the
    ///     connect ceiling).
    ///   - connectServer: builds the one-shot connection `listShares` runs over.
    public init(
        pool: SMBConnectionPool<Connection>,
        credentials: SMBCredentials,
        connectTimeout: TimeInterval = 15,
        connectServer: @escaping SMBConnectionBuilder<Connection>
    ) {
        self.pool = pool
        self.credentials = credentials
        self.connectTimeout = connectTimeout
        self.connectServer = connectServer
    }

    /// Enumerates the server's shares. `enumerateHidden: false` excludes `$`-admin shares.
    ///
    /// Runs on its own connection (see the type comment): the pool keys on share, and this call has
    /// none. Both exits hand the connection to the SAME background graceful teardown, which drains
    /// any still-running native call before the context is destroyed. Fire-and-forget on purpose,
    /// on both paths: nothing the caller does depends on the teardown finishing, and awaiting it is
    /// the one place left where a wedged drain could re-stall a caller that the ceiling just freed.
    public func listShares() async throws -> [SMBShare] {
        // Share is empty on purpose: share enumeration opens IPC$ itself, so only the host, domain
        // and credential of this target are used.
        let target = SMBConnectionTarget(credentials: credentials, share: "")
        // The build itself can fail with a connection already standing (see `SMBConnectionBuilder`),
        // and this call OWNS its connection outright — nothing else holds a reference to dispose of
        // one it never returned. The escrow is what gives that half-built case an owner.
        let escrow = SMBConnectionEscrow<Connection>()
        let connection: Connection
        do {
            connection = try await connectServer(target) { escrow.deliver($0) }
        } catch {
            pool.claimAbandonedConnect(
                escrow, failedWith: error, settlement: SMBOperationSettlement(),
                operationTimeout: operationCeiling
            )
            throw error
        }
        connection.setOperationTimeout(operationCeiling)
        let settlement = SMBOperationSettlement()
        do {
            let shares = try await bounded(settlement: settlement) { try await connection.availableShares() }
            Self.tearDown(connection)
            return shares
        } catch {
            // Same split as `list`: an enumeration that FINISHED badly is torn down (the drain finds
            // nothing pending), while one still running on a wedged socket is condemned — tearing that
            // one down is the graceful-disconnect crash, one-shot connection or not.
            if settlement.isAbandoned {
                await pool.condemn(connection, settlement: settlement)
            } else if SMBAbandonedCall.leavesRequestQueued(error) {
                // Nothing will ever settle this receipt (the reply timeout left the request queued
                // in libsmb2), so it carries the fuse that bounds the park — see `list`.
                await pool.condemn(connection, settlement: settlement, releaseAfter: releaseFuse)
            } else {
                Self.tearDown(connection)
            }
            throw error
        }
    }

    /// Background graceful teardown of the one-shot enumeration connection. Unstructured `Task` does
    /// NOT inherit the caller's cancellation, so a cancelled `listShares` still drains and closes
    /// instead of abandoning the connection to its own deinit.
    private static func tearDown(_ connection: Connection) {
        Task { await connection.disconnectGracefully() }
    }

    /// Lists one directory level of `share` at `path`, non-recursive. Borrows a warm connection for
    /// `share` from the pool, returns it on success, and never returns it to the pool on failure —
    /// discarded when the listing FINISHED badly, condemned when it is still running.
    ///
    /// **One retry, and only for a dead warm borrow.** After device sleep every pooled socket is a
    /// corpse the pool cannot tell apart from a live one — and since a key now keeps a warm
    /// connection indefinitely (`SMBConnectionPool.reapIdle`), the first folder opened after waking is
    /// handed exactly that corpse. Surfacing its transport failure would put an error scrim in front
    /// of a user whose server is perfectly reachable, so a WARM borrow that died on the transport is
    /// disposed of by the normal rules and the listing is retried ONCE on a guaranteed-fresh
    /// connection. Everything else surfaces immediately: a FRESH connection that failed means the
    /// server really is unreachable, a sign-in/permission/not-found failure is a real answer, and a
    /// still-pending call belongs to the graveyard, not to a retry.
    public func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        do {
            return try await attemptList(share: share, path: path, requireFresh: false)
        } catch let failure as ListAttemptFailure {
            guard failure.deservesFreshRetry else { throw failure.underlying }
            do {
                return try await attemptList(share: share, path: path, requireFresh: true)
            } catch let retried as ListAttemptFailure {
                // The second failure is the answer — never a third attempt.
                throw retried.underlying
            }
        }
    }

    /// One listing attempt over one borrow. Wraps whatever the listing threw in a
    /// `ListAttemptFailure` so `list` can see BOTH the error and whether the borrow that produced it
    /// was a warm one; a failure from the checkout itself is not a borrow failure and passes through
    /// untouched.
    private func attemptList(
        share: String,
        path: String,
        requireFresh: Bool
    ) async throws -> [SMBDirectoryEntry] {
        let target = SMBConnectionTarget(credentials: credentials, share: share)
        let borrowed = try await pool.checkout(target, requireFresh: requireFresh)
        let connection = borrowed.connection
        // Warm reuse inherits the previous borrower's ceiling, so re-assert ours. Nothing between
        // here and the `do` may throw or suspend: a borrow that escaped the do/catch would reach
        // neither `checkin` nor the failure paths.
        connection.setOperationTimeout(operationCeiling)
        let listPath = path.isEmpty ? "/" : path
        let settlement = SMBOperationSettlement()
        do {
            let entries = try await bounded(settlement: settlement) {
                try await connection.directoryEntries(atPath: listPath)
            }
            // Check in DETACHED: the folder the user just opened is on screen the moment these
            // entries return, and pool hygiene (reaping, cap eviction) must not be charged to it —
            // on a real NAS each teardown it triggers is a tree-disconnect plus a logoff round trip.
            // The cost is that a listing fired immediately after this one may cold-connect instead of
            // reusing this borrow, which the pool absorbs by cap and reap.
            Task { await pool.checkin(borrowed) }
            return entries
        } catch {
            // No failure exit ever returns the borrow to the pool — the socket is at best of unknown
            // state — but HOW it leaves splits on one question: is the native call still running?
            //
            //  - Finished badly (the server said no, the socket returned an error): DISCARD. The
            //    graceful teardown finds nothing pending, which is the case it has always served.
            //  - Still running (the hard ceiling fired, or the caller was cancelled while libsmb2 sat
            //    in its poll loop): CONDEMN. Disconnecting that — gracefully included — is a crash,
            //    not a cleanup; see `SMBConnectionGraveyard`. The settlement tells the two apart
            //    because `withHardTimeout` marks it before it resumes us, and it is also what later
            //    releases the parked connection.
            //  - Finished badly with AMSMB2's OWN reply timeout: also CONDEMN, but with a FUSE. That
            //    error looks like a completed failure but leaves the request queued inside libsmb2 —
            //    see `SMBAbandonedCall`. Nothing will ever settle this one, so without the fuse it
            //    parks for good, leaking a socket and a server session per slow listing. The call
            //    itself has RETURNED here, which is what makes a timed release safe.
            //
            // Cancellation is deliberately never a check-in: the native call cannot observe it, so a
            // cancelled listing leaves the socket mid-response exactly like a wedged one. The cost is
            // that a cancelled browse burns a warm connection; correctness wins.
            var deservesFreshRetry = false
            if settlement.isAbandoned {
                await pool.condemn(borrowed, settlement: settlement)
            } else if SMBAbandonedCall.leavesRequestQueued(error) {
                await pool.condemn(borrowed, settlement: settlement, releaseAfter: releaseFuse)
            } else {
                pool.discard(borrowed)
                // Only here: the call RETURNED, so a retry cannot be racing anything still pending.
                // Cancellation is excluded by hand — nobody wants the listing any more, and it
                // classifies as a lost connection only because it has no POSIX code of its own.
                deservesFreshRetry = borrowed.isWarm
                    && !(error is CancellationError)
                    && SMBFileSource.isTransportFailure(error)
            }
            throw ListAttemptFailure(underlying: error, deservesFreshRetry: deservesFreshRetry)
        }
    }

    /// One attempt's failure, plus whether the borrow behind it was a warm one that died on the
    /// transport — the only shape `list` retries. Never escapes this type: `list` unwraps it.
    private struct ListAttemptFailure: Error {
        let underlying: any Error
        let deservesFreshRetry: Bool
    }

    /// The per-operation ceiling actually pinned on a connection. Clamped at zero because tests
    /// derive a sub-second `bounded` ceiling by subtracting the hard-timeout grace from it, which
    /// can go negative — `bounded` adds the grace back, but a negative value must never reach a
    /// real connection's timeout setter.
    private var operationCeiling: TimeInterval {
        max(0, connectTimeout)
    }

    /// How long a park nobody can ever settle holds its connection before the graveyard lets go.
    /// Sized off the same ceiling the operation ran under — see `SMBAbandonedCall.releaseFuse`.
    private var releaseFuse: Duration {
        SMBAbandonedCall.releaseFuse(afterOperationTimeout: operationCeiling)
    }

    /// Outer wall-clock ceiling on one AMSMB2 operation. AMSMB2's own `timeout` bounds SMB PDU
    /// responses but NOT every phase — on device, name resolution can block far past it — so every
    /// await on a connection goes through this bound too. The grace over `connectTimeout` lets
    /// AMSMB2's more specific error win whenever its own timeout does fire. See `withHardTimeout`
    /// for why the loser keeps running detached: that detached task is what holds the connection
    /// alive while the abandoned call finishes.
    private func bounded<T: Sendable>(
        settlement: SMBOperationSettlement? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withHardTimeout(
                seconds: connectTimeout + SMBConnectionPool<Connection>.hardTimeoutGrace,
                settlement: settlement,
                operation: operation
            )
        } catch is HardTimeoutError {
            throw SMBListerError.timedOut
        }
    }
}

// MARK: - Convenience: SMB2Manager-backed lister

extension PooledSMBLister where Connection == SMB2Manager {

    /// Production lister: shares the app's `SMBSharePool`, and builds share enumeration's one-shot
    /// connection as a plain `SMB2Manager` with no share attached (AMSMB2 opens IPC$ itself).
    public init(
        pool: SMBSharePool,
        credentials: SMBCredentials,
        connectTimeout: TimeInterval = 15
    ) {
        self.init(
            pool: pool, credentials: credentials, connectTimeout: connectTimeout,
            connectServer: { target, deliver in
                guard let client = SMB2Manager(
                    url: target.serverURL, domain: target.domain, credential: target.credential
                ) else {
                    throw SMBListerError.managerInitFailed
                }
                client.timeout = max(0, connectTimeout)
                deliver(client)
                return client
            }
        )
    }
}

// MARK: - Connection abstraction

/// The enumerations a pooled SMB connection must serve for `PooledSMBLister`, layered on the pool's
/// own `PoolableSMBConnection` lifecycle contract. Production conforms `SMB2Manager` (below); tests
/// conform a fake, so the borrow/discard lifecycle above is testable without a live share.
///
/// Both members are deliberately thin renames of AMSMB2's own API rather than a wider abstraction:
/// its raw results are non-`Sendable` attribute dictionaries and name/comment tuples, so the mapping
/// to the neutral types has to happen inside the conformance anyway.
public protocol SMBListableConnection: PoolableSMBConnection {
    /// One directory level at `path`, non-recursive.
    func directoryEntries(atPath path: String) async throws -> [SMBDirectoryEntry]

    /// The server's visible shares (hidden `$`-admin shares excluded). Opens its own IPC$
    /// connection, so it does not need — and does not preserve — an attached share.
    func availableShares() async throws -> [SMBShare]
}

extension SMB2Manager: SMBListableConnection {
    public func directoryEntries(atPath path: String) async throws -> [SMBDirectoryEntry] {
        // Mapped here, not at the call site: AMSMB2's raw attribute dictionaries are
        // `[URLResourceKey: Any]` (not Sendable), so only the neutral entries may leave.
        try await contentsOfDirectory(atPath: path, recursive: false).map { attrs in
            SMBDirectoryEntry(
                name: attrs.name ?? "",
                isDirectory: attrs.isDirectory,
                size: attrs.fileSize ?? 0,
                modifiedAt: attrs.contentModificationDate,
                createdAt: attrs.creationDate
            )
        }
    }

    public func availableShares() async throws -> [SMBShare] {
        try await listShares(enumerateHidden: false).map { SMBShare(name: $0.name, comment: $0.comment) }
    }
}
