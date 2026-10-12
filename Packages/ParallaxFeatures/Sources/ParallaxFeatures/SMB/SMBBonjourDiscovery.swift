import Foundation
import Network
import Observation
import os
import ParallaxCore

/// Discovers SMB hosts on the local network via Bonjour (`_smb._tcp`).
///
/// This is a convenience layer — results pre-fill the add-server form's host
/// field but require no connection to browse. True host resolution (service
/// name → IP) happens inside `NWConnection` at connect time; resolving every
/// discovered service eagerly is a Bonjour anti-pattern.
///
/// **Host limitation:** `discoveredServer(forServiceName:)` synthesises
/// `<name>.local` as the connectable host. This works for mDNS on the same
/// LAN segment but may not resolve over VPN or after the mDNS TTL lapses.
/// Upgrade path: pass the discovered `NWEndpoint` directly to `NWConnection`
/// (the framework resolves on demand), then surface the resolved IP once the
/// connection reaches `.ready`. That upgrade is deferred — it requires an
/// active connection just to learn the IP, which is overkill for a discovery
/// picker.
@Observable
@MainActor
public final class SMBBonjourDiscovery {
    public private(set) var discovered: [SMBDiscoveredServer] = []
    public private(set) var isDiscovering = false

    /// Starts one live browse: a stream of the COMPLETE set of service names currently on the
    /// network, re-sent on every change, that stops browsing when its consumer goes away.
    private let browse: @Sendable () -> AsyncStream<[String]>
    private var browsing: Task<Void, Never>?

    public init(browse: @escaping @Sendable () -> AsyncStream<[String]>) {
        self.browse = browse
    }

    public func start() {
        guard browsing == nil else { return }
        // Fresh scan each time the picker opens; `ingest` then reconciles against each
        // snapshot, so a host that later leaves the network drops out on its own.
        discovered = []
        Log.network.info("SMB Bonjour discovery starting")
        let names = browse()
        isDiscovering = true
        browsing = Task { [weak self] in
            for await snapshot in names {
                self?.ingest(snapshot)
            }
            // The browser failed or was cancelled; a later `start()` opens a fresh one.
            self?.browsing = nil
            self?.isDiscovering = false
        }
    }

    public func stop() {
        browsing?.cancel()
        browsing = nil
        isDiscovering = false
        Log.network.info("SMB Bonjour discovery stopped")
    }

    // MARK: - Result ingestion

    private func ingest(_ names: [String]) {
        // Each snapshot is the COMPLETE current set, so reconcile `discovered` against it rather
        // than appending — a host that left the network (its service dropped from the set) must
        // stop being offered as a connectable row, not linger until the picker is reopened.
        // Sorted by name for stable row order.
        let servers = Set(names).sorted().map { Self.discoveredServer(forServiceName: $0) }
        guard servers != discovered else { return }
        discovered = servers
        Log.network.info("SMB Bonjour: \(servers.count) host(s) currently on the network")
    }

    // MARK: - Live browsing

    /// `_smb._tcp` service names from an `NWBrowser`, for `browse`. Every change delivers the
    /// complete current set; a failed browser ends the stream, and ending the stream cancels it.
    public nonisolated static func liveServiceNames() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp
            )
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Log.network.info("SMB Bonjour browser ready")
                case .failed(let error):
                    Log.network.error("SMB Bonjour browser failed: \(error)")
                    continuation.finish()
                case .cancelled:
                    Log.network.info("SMB Bonjour browser cancelled")
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return name
                })
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .main)
        }
    }

    // MARK: - Pure mapping (unit-testable)

    /// Maps a Bonjour service instance name to an `SMBDiscoveredServer`.
    ///
    /// The synthesised host `"<name>.local"` is best-effort — it relies on
    /// mDNS and works on the same LAN segment. See type-level doc for the
    /// upgrade path to true IP resolution.
    nonisolated static func discoveredServer(forServiceName name: String) -> SMBDiscoveredServer {
        SMBDiscoveredServer(id: name, name: name, host: "\(name).local")
    }
}
