import Foundation

public enum QuickConnectStatus: Sendable, Hashable {
    case waitingForCode
    case polling(code: String)
    case signedIn(Session)
    case rejected
    case expired
}
