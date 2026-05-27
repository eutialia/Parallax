//
//  ParallaxApp.swift
//  Parallax
//
//  Created by Linghao Hsu on 2026-05-26.
//

import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback

@main
struct ParallaxApp: App {
    @State private var dependencies: AppDependencies = .live()
    @State private var router: AppRouter = .init()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(router)
                .task {
                    do {
                        try await dependencies.serverStore.load()
                    } catch {
                        ParallaxCore.Log.persistence.error("ServerStore.load failed: \(error.localizedDescription)")
                    }
                    router.updateForCurrentSession(await dependencies.serverStore.active)
                }
        }
    }
}
