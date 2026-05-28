import Foundation

public enum ImageKind: Sendable, Hashable {
    case primary
    case backdrop(index: Int)
    case logo
    case thumb
    case banner
    case art
    case disc

    // Wire-format segment used in /Items/{id}/Images/{segment}[/{index}]
    var pathSegment: String {
        switch self {
        case .primary: return "Primary"
        case .backdrop: return "Backdrop"
        case .logo: return "Logo"
        case .thumb: return "Thumb"
        case .banner: return "Banner"
        case .art: return "Art"
        case .disc: return "Disc"
        }
    }
}
