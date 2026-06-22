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
final class SMBBonjourDiscovery {
    private(set) var discovered: [SMBDiscoveredServer] = []
    private(set) var isDiscovering = false

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        // Fresh scan each time the picker opens; `ingest` then reconciles against each
        // snapshot, so a host that later leaves the network drops out on its own.
        discovered = []
        Log.network.info("SMB Bonjour discovery starting")

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_smb._tcp", domain: "local.")
        let b = NWBrowser(for: descriptor, using: .tcp)

        // Both handlers are delivered on the queue passed to start(queue:).
        // We use .main so MainActor.assumeIsolated is correct — we're on the
        // main thread and know it, but the closure type is nonisolated.
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    Log.network.info("SMB Bonjour browser ready")
                case .failed(let error):
                    Log.network.error("SMB Bonjour browser failed: \(error)")
                    self.stop()
                case .cancelled:
                    Log.network.info("SMB Bonjour browser cancelled")
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.ingest(results)
            }
        }

        b.start(queue: .main)
        browser = b
        isDiscovering = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isDiscovering = false
        Log.network.info("SMB Bonjour discovery stopped")
    }

    // MARK: - Result ingestion

    private func ingest(_ results: Set<NWBrowser.Result>) {
        // NWBrowser delivers the COMPLETE current result set on every change, so reconcile
        // `discovered` against it rather than appending — a host that left the network (its
        // service dropped from the set) must stop being offered as a connectable row, not
        // linger until the picker is reopened. Sorted by name for stable row order.
        let names = results.compactMap { result -> String? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return name
        }
        let servers = Set(names).sorted().map { Self.discoveredServer(forServiceName: $0) }
        guard servers != discovered else { return }
        discovered = servers
        Log.network.info("SMB Bonjour: \(servers.count) host(s) currently on the network")
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
