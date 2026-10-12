import Observation
import ParallaxFeatures

/// What views read through the environment: the package graph `AppModel` built, reached by member
/// lookup.
@Observable
@MainActor
@dynamicMemberLookup
final class AppDependencies {
    let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<AppServices, Value>) -> Value {
        services[keyPath: keyPath]
    }
}
