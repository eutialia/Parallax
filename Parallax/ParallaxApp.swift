//
//  ParallaxApp.swift
//  Parallax
//
//  Created by Linghao Hsu on 2026-05-26.
//

import SwiftUI
import os
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback

@main
struct ParallaxApp: App {
    @State private var dependencies: AppDependencies = .live()
    @State private var router: AppRouter = .init()
    @State private var playback: PlaybackPresenter = .init()
    @State private var launchGate: LaunchGate = .init()

    /// Boot into the poster-tile focus spike screen (PosterFocusSpike.swift) instead of
    /// the app — Debug-only diagnostic for on-device focus A/Bs.
    private let posterFocusSpike = false

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if posterFocusSpike {
                PosterFocusSpikeScreen()
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
    }

    private var appRoot: some View {
        RootView()
            .environment(dependencies)
            .environment(router)
            .environment(playback)
            .environment(launchGate)
            .task {
                do {
                    try await dependencies.serverStore.load()
                } catch {
                    ParallaxCore.Log.persistence.error("ServerStore.load failed: \(error.localizedDescription)")
                }
                router.updateForSources(
                    activeSession: await dependencies.serverStore.active,
                    hasAuxiliarySources: await dependencies.serverStore.hasSMBServers
                )

                // Rebuild the device profile on the next resolve whenever
                // the audio route changes (e.g. AirPlay connects). Per the
                // spec, in-flight playback is intentionally NOT interrupted.
                Task {
                    for await _ in dependencies.audioSession.routeChanges {
                        await dependencies.deviceProfileBuilder.invalidate()
                    }
                }
            }
    }
}
