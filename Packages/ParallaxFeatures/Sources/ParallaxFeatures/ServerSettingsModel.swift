import Foundation
import Observation
import ParallaxJellyfin

/// What the per-server settings page shows beyond the saved session: whether the server answers, its
/// version, and how many of its libraries are visible.
@Observable
@MainActor
public final class ServerSettingsModel {
    /// Point-in-time reachability of the server, derived from the public-info probe.
    public enum ConnectionStatus { case checking, connected, offline }

    public private(set) var status: ConnectionStatus = .checking
    /// Fetched server version ("10.9.11"); nil until the probe lands, and after a failed one.
    public private(set) var version: String?
    /// "4 of 6" / "All" summary for the Visible Libraries row.
    public private(set) var visibleSummary = "All"

    private let session: Session
    private let app: AppModel

    public init(session: Session, app: AppModel) {
        self.session = session
        self.app = app
    }

    /// Fetch the server version + reachability from the unauthenticated public-info endpoint. A thrown
    /// request (offline / wrong host) flips the pill to "Offline"; the version stays nil.
    public func probeServer() async {
        let client = await app.services.clientFactory.make(serverURL: session.serverURL)
        do {
            version = try await client.serverVersion()
            status = .connected
        } catch {
            status = .offline
        }
    }

    /// Compute the "N of M" / "All" Visible Libraries summary from the server's collections + hidden set.
    /// A fetch failure leaves the previous label (the row stays useful even if the server is briefly down).
    public func loadLibrarySummary() async {
        let hidden = await app.services.serverStore.hiddenCollectionIDs(for: session.id)
        guard let collections = try? await app.services.jellyfinLibraryRepoFactory(session).collections() else { return }
        // A newer revision (e.g. rapid visibility toggles) cancels this task; don't let a stale fetch
        // that resolved after the cancel overwrite the fresher summary the newer task already wrote.
        guard !Task.isCancelled else { return }
        let total = collections.count
        let visible = collections.filter { !hidden.contains($0.id.rawValue) }.count
        visibleSummary = (total == 0 || visible == total) ? "All" : "\(visible) of \(total)"
    }
}
