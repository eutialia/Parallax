import SwiftUI

enum AppIdiom: Equatable {
    /// Any screen short of regular × regular: iPhone, iPad Split View slices.
    case compact
    /// A regular × regular screen: iPad, the iPhone Duo's open inner display.
    case regular
    case tv

    /// Content layout follows the screen, not the device. Both axes regular, so a Pro Max in
    /// landscape (regular × compact) keeps the compact forms.
    init(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
        self = horizontal == .regular && vertical == .regular ? .regular : .compact
    }

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
    /// The root shows the iPad sidebar (`RootTabView.isSidebarLayout`), which the hero mirrors under.
    @Entry var showsSidebar = false
}