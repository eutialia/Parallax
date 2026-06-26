import ParallaxJellyfin

/// Display formatting for a persisted SMB server — kept app-side (like `Session+Display`) so the
/// package model stays presentation-free. One source of truth for the subtitle shown on the settings
/// root row and the server detail.
extension SMBServerData {
    /// The subtitle shown on the settings root row: "1 share" / "N shares".
    var shareCountSubtitle: String { shares.count == 1 ? "1 share" : "\(shares.count) shares" }
}
