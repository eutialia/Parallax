import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Backs one level of `SMBBrowseView`: lists a single directory of a share into name-sorted
/// subfolders (drill targets) and playable media. One view model per browsed level — each
/// `SMBBrowseView` builds its own lister/`SMBFileSource` (an `AMSMB2Lister` is an actor, so it
/// can't ride the `Hashable` nav value) and tears it down on disappear.
///
/// Loading cancels any in-flight task before starting a new one; a stale-guard on the current
/// path ensures a slow, cancelled load can't overwrite the live directory. The level's path is
/// fixed for the model's lifetime, so the guard collapses to the cancellation check — but it's
/// kept explicit so the pattern remains readable. Failures map through `SMBFileSource.mapListError`
/// to the same `AppError` `userMessage` the Jellyfin grid surfaces (`LibraryGridViewModel`), so
/// SMB and Jellyfin errors read in one voice.
@Observable
@MainActor
final class SMBBrowseViewModel {
    private(set) var folders: [SMBDirectoryEntry] = []
    private(set) var media: [Item] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private let source: SMBFileSource
    private let share: String
    private let path: String
    private var loadTask: Task<Void, Never>?

    init(source: SMBFileSource, share: String, path: String) {
        self.source = source
        self.share = share
        self.path = path
    }

    func load() {
        isLoading = true
        error = nil
        loadTask?.cancel()
        loadTask = Task { [source, share, path] in
            defer { isLoading = false }
            do {
                let listing = try await source.browse(in: path)
                guard !Task.isCancelled else { return }
                folders = listing.folders
                media = listing.media
            } catch {
                guard !Task.isCancelled else { return }
                self.error = SMBFileSource.mapListError(error, share: share, path: path).userMessage
            }
        }
    }

    /// Cancel the in-flight list and drop the share connection. Called from the view's
    /// `.onDisappear` regardless of how the level leaves (back, deeper push, app background);
    /// `SMBFileSource.disconnect()` forwards to the lister actor, so it's safe from MainActor.
    func teardown() {
        loadTask?.cancel()
        Task { [source] in await source.disconnect() }
    }
}
