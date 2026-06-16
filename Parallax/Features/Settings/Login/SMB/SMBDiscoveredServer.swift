import Foundation

/// An SMB host found via Bonjour (`_smb._tcp`). `host` pre-fills the add-server
/// form's host field; the user can edit it (mDNS gives a service name, not always
/// a directly-connectable host).
///
/// True host resolution (service name → IP) happens lazily via `NWConnection`
/// when the user actually connects — resolving every discovered service up front
/// is a Bonjour anti-pattern and is out of scope here.
struct SMBDiscoveredServer: Sendable, Hashable, Identifiable {
    /// Stable per service instance (the mDNS service name).
    let id: String
    /// Human-facing instance name shown in discovery UI.
    let name: String
    /// Best-effort connectable host to pre-fill (e.g. `"<name>.local"`).
    /// The user should be able to edit this before connecting — mDNS `.local`
    /// resolution works on the same LAN but may fail over VPN or after the
    /// connection window lapses.
    let host: String
}
