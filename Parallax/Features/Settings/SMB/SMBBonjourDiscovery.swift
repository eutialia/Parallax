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
    private var seenIDs: Set<String> = []

    func start() {
        guard browser == nil else { return }
        // Fresh scan each time the picker opens — a prior session's hosts may be
        // gone, and `browseResultsChangedHandler` only re-reports them if they're
        // newly seen relative to `seenIDs`.
        discovered = []
        seenIDs = []
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
        let before = discovered.count
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            guard seenIDs.insert(name).inserted else { continue }
            discovered.append(Self.discoveredServer(forServiceName: name))
        }
        let added = discovered.count - before
        if added > 0 {
            Log.network.info("SMB Bonjour: \(added) new host(s) discovered (\(self.discovered.count) total)")
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
