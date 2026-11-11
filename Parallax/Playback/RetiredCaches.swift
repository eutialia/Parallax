import Foundation

/// Caches directories earlier versions wrote and nothing reads anymore. Tens of megabytes of
/// copied font files, so they are removed at launch instead of left for the system to purge.
nonisolated enum RetiredCaches {
    private static let directoryNames = ["parallax-fonts", "parallax-vlc-fonts"]

    static func prune() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        for name in directoryNames {
            try? FileManager.default.removeItem(at: caches.appending(path: name, directoryHint: .isDirectory))
        }
    }
}
