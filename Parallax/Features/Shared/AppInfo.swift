import Foundation

/// The app's bundle identity, read once from Info.plist — the single source for version strings.
/// Consumers: the Jellyfin client identity (`AppDependencies`) and the Settings → About Version row.
enum AppInfo {
    /// Marketing version, e.g. "1.0".
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Build number, e.g. "142".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// The display string for the About row — the only place the version shows in the UI.
    static var versionText: String { "Parallax \(shortVersion) (\(build))" }
}
