import Foundation
import ParallaxJellyfin

extension Session {
    /// The host shown in server cards and other settings copy.
    /// One fallback for the whole app so the same server never reads differently in two
    /// places when `URL.host()` is nil.
    var displayHost: String {
        serverURL.host() ?? serverName
    }
}
