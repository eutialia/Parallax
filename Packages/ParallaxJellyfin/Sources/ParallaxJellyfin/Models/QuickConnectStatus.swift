import Foundation

public enum QuickConnectStatus: Sendable, Hashable {
    case waitingForCode
    case polling(code: String)
    case signedIn(Session)
    case expired
    /// Any non-expired failure (network, server, post-auth fetch). `reason`
    /// is a short, user-facing message ready to render.
    case failed(reason: String)
}
