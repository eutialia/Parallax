import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class HomeViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var continueWatching: [Item] = []
    private(set) var nextUp: [Item] = []

    private let repo: LibraryRepository

    init(repo: LibraryRepository) {
        self.repo = repo
    }

    func load() async {
        state = .loading
        do {
            async let cwTask = repo.continueWatching()
            async let nuTask = repo.nextUp()
            let (cw, nu) = try await (cwTask, nuTask)
            self.continueWatching = cw
            self.nextUp = nu
            self.state = .loaded
        } catch let error as AppError {
            Log.ui.error("HomeViewModel load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("HomeViewModel load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }
}
