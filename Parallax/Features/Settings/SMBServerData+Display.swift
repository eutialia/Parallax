import ParallaxJellyfin

/// Display formatting for a persisted SMB source — kept app-side (like `Session+Display`) so the package
/// model stays presentation-free. One source of truth for the `/share/root` path and leaf name that the
/// settings root row, the per-host detail, the Mounted Folders list, and the folder picker all render —
/// before this they each rebuilt the same string inline and could drift.
extension SMBServerData {
    /// The `/share/root` path shown in the UI (e.g. `/Media/Anime`); `/share` when mounted at the root.
    var displayPath: String { Self.displayPath(share: share, root: root) }

    /// The folder's leaf name — the last `root` component, or the share itself at the share root.
    var folderName: String {
        root.isEmpty ? share : (root.split(separator: "/").last.map(String.init) ?? share)
    }

    /// `/share/root` from raw components — for the live folder picker, which formats a path it is still
    /// browsing and has no persisted `SMBServerData` yet.
    static func displayPath(share: String, root: String) -> String {
        "/" + share + (root.isEmpty ? "" : "/\(root)")
    }
}
