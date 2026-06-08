import SwiftUI

enum AppIdiom: Equatable {
    case compact   // iPhone
    case regular   // iPad
    case tv        // Apple TV

    /// Landscape hero band (iPad + TV) vs poster band (iPhone).
    var usesLandscapeHeroBand: Bool {
        switch self {
        case .compact: false
        case .regular, .tv: true
        }
    }
}

extension EnvironmentValues {
    @Entry var appIdiom: AppIdiom = .compact
}