#if DEBUG
import Foundation
import ParallaxCore
import ParallaxJellyfin

extension Session {
    /// Inert Jellyfin session for `#Preview`s: the `.invalid` TLD guarantees image requests
    /// fail fast to placeholders, so previews render deterministic offline chrome.
    static let preview = Session(
        id: ServerID(rawValue: "preview"),
        data: JellyfinServerData(
            serverURL: URL(string: "https://preview.invalid")!,
            serverName: "Preview",
            user: UserSnapshot(id: "u1", name: "preview", serverLastUpdatedAt: nil)
        ),
        accessToken: "preview"
    )
}
#endif
