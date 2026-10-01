import SwiftUI

extension EnvironmentValues {
    /// The system's `systemPrefersReducedResourceUsage`, readable on the 26 floor where it is always
    /// false. Published once at the root by `bridgesReducedResourceUsage()`.
    @Entry var prefersReducedResourceUsage = false
}

extension View {
    func bridgesReducedResourceUsage() -> some View {
        modifier(ReducedResourceUsageBridge())
    }
}

private struct ReducedResourceUsageBridge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27, tvOS 27, *) {
            content.modifier(SystemReducedResourceUsageReader())
        } else {
            content
        }
    }
}

@available(iOS 27, tvOS 27, *)
private struct SystemReducedResourceUsageReader: ViewModifier {
    @Environment(\.systemPrefersReducedResourceUsage) private var systemPrefersReduced

    func body(content: Content) -> some View {
        content.environment(\.prefersReducedResourceUsage, systemPrefersReduced)
    }
}
