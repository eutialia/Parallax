import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

/// Resolves a poster for a source-neutral `Item` that carries no server artwork — today only the
/// SMB path, which generates a frame-grab from the video itself.
///
/// Owns the whole generation pipeline so the call site (a grid tile's `.task`) stays trivial:
///   disk-cache hit (instant) → negative-cache skip (instant) → gated generation on a real miss.
///
/// **Why an actor in front of the cache.** `SMBThumbnailCache` is a pure disk layer; it has no
/// concurrency limit and no failure memory. This provider adds the three things a NAS needs:
/// a single-permit gate (one libVLC `smb://` demux at a time — parallel libsmb2 connects are
/// flaky and one stream saturates a home LAN); coalescing (a re-check of the disk after acquiring
/// the permit, so two tasks racing for the same key don't both demux it); and an in-memory
/// negative cache so a permanently undecodable file isn't re-attempted (and re-charged the 20s
/// timeout) on every scroll-past.
///
/// **Credentials** never leave this file in the clear: they're read from the Keychain via
/// `SMBSourceResolver` and ride `vlcOptions` into `VLCThumbnailer`, which never logs them.
actor MediaArtworkProvider {

    private let cache: SMBThumbnailCache
    /// `@MainActor`-isolated; constructed on the main actor in `AppDependencies` and called via
    /// `await` (it hops to main for the actual decode).
    private let thumbnailer: VLCThumbnailer
    private let keychain: any KeychainStoring

    /// One permit — serialises SMB frame-grabs. See the type doc for why 1 (device-tune upward
    /// only with on-NAS measurement).
    private let gate = ThumbnailGate()

    /// Keys whose generation recently failed, with when. In-memory only: a relaunch clears it so a
    /// transient NAS outage self-heals. Entries self-expire on the next lookup past the backoff.
    private var failures: [SMBThumbnailKey: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    private static let failureBackoff: Duration = .seconds(180)

    init(
        thumbnailer: VLCThumbnailer,
        keychain: any KeychainStoring,
        cache: SMBThumbnailCache = SMBThumbnailCache()
    ) {
        self.thumbnailer = thumbnailer
        self.keychain = keychain
        self.cache = cache
    }

    /// The artwork for a browsed SMB `Item`, generating + caching a frame-grab on a miss.
    ///
    /// Order matters for cost: the cache key is built from the ItemID's decoded path alone (no
    /// Keychain), so a disk hit or a negative-cache skip returns WITHOUT a Keychain round-trip or
    /// the gate. Only a genuine miss pays for credential assembly + gated generation.
    ///
    /// Returns `.local(url)` once a thumbnail exists on disk, or `.none` while one can't be
    /// produced. Safe to call from a SwiftUI `.task`: cancellation (scroll-off) propagates through
    /// the gate and into `VLCThumbnailer`, freeing the single permit for a still-visible tile.
    func artwork(for item: Item, ref: SMBServerRef) async -> ArtworkSource {
        // SMB library items are flat movies; anything else carries server artwork already.
        guard case .movie(let movie) = item else { return .none }
        // The share-relative path decodes from the ItemID with no Keychain read, so the key (and
        // thus the cache + negative-cache lookups) is available before any I/O.
        guard let path = SMBSourceResolver.sharePath(for: item, ref: ref) else { return .none }
        let key = SMBThumbnailKey(
            serverID: ref.id.rawValue,
            path: path,
            size: movie.size ?? 0,
            modifiedAt: movie.dateAdded
        )

        if let hit = await cache.existingURL(for: key) { return .local(hit) }
        if isNegativelyCached(key) { return .none }

        // Real miss → assemble credentials (the only Keychain read) + the smb:// URL.
        let ctx: SMBSourceContext
        do {
            ctx = try await SMBSourceResolver.context(for: item, ref: ref, keychain: keychain)
        } catch {
            // Bad ItemID / unbuildable URL — not a decode failure, so don't poison the key.
            return .none
        }

        // Serialise generation (cap=1). A scroll-off while queued throws and never acquires the
        // permit, so there's nothing to release.
        do { try await gate.wait() } catch { return .none }
        let result = await generateUnderGate(key: key, ctx: ctx)
        await gate.signal()
        return result
    }

    /// Runs under the held single permit. Re-checks the disk first so two tasks that raced for the
    /// same key collapse to one demux (coalescing), then generates and stores.
    private func generateUnderGate(key: SMBThumbnailKey, ctx: SMBSourceContext) async -> ArtworkSource {
        // A sibling task for the same key may have written it while we waited for the permit.
        if let hit = await cache.existingURL(for: key) { return .local(hit) }
        if isNegativelyCached(key) { return .none }

        do {
            // Defaults bake in the agreed frame: height 320, position 0.3, 20s hard timeout.
            let data = try await thumbnailer.thumbnailData(for: ctx.url, options: ctx.vlcOptions)
            // A nil from store() is a WRITE failure, not a decode failure — return .none but do
            // NOT poison the key, so the next scroll retries instead of hiding a decodable file.
            return (await cache.store(data, for: key)).map(ArtworkSource.local) ?? .none
        } catch {
            // Generation failed/timed out. Poison ONLY if this wasn't a scroll-off cancellation —
            // a cancelled fetch also throws (.timedOut), and `Task.isCancelled` is the reliable
            // discriminator regardless of the thrown error type. (A real timeout IS poisoned by
            // design: that's what stops re-charging the 20s wait on every scroll-past.)
            if !Task.isCancelled { recordFailure(key) }
            return .none
        }
    }

    // MARK: - Negative cache

    private func isNegativelyCached(_ key: SMBThumbnailKey) -> Bool {
        guard let failedAt = failures[key] else { return false }
        if clock.now - failedAt < Self.failureBackoff { return true }
        failures.removeValue(forKey: key)
        return false
    }

    private func recordFailure(_ key: SMBThumbnailKey) {
        failures[key] = clock.now
    }
}

/// FIFO async semaphore with a single permit. `wait()` throws `CancellationError` if the calling
/// task is cancelled before it acquires the permit, so a scrolled-off tile gives up its place in
/// line instead of holding visible tiles behind it. A waiter handed the permit just before its own
/// cancellation still acquires it; its in-flight generation then cancels and releases normally, so
/// the permit is always conserved.
private actor ThumbnailGate {
    private var available = 1
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func wait() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            // Hand the permit straight to the next waiter (available stays 0).
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
