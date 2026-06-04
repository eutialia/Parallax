import Foundation
import ParallaxJellyfin

extension Session {
    /// The host shown in account chrome (sidebar footer, settings header, server cards).
    /// One fallback for the whole app so the same server never reads differently in two
    /// places when `URL.host()` is nil.
    var displayHost: String {
        serverURL.host() ?? serverName
    }
}
