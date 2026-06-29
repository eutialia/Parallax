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
    // Vends `OrientationController`'s mask to UIKit — the only orientation hook a SwiftUI
    // lifecycle app reaches. iOS only: tvOS has no interface orientation.
    #if !os(tvOS)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    #endif

    @State private var dependencies: AppDependencies = .live()
    @State private var router: AppRouter = .init()
    @State private var playback: PlaybackPresenter = .init()
    @State private var launchGate: LaunchGate = .init()
    /// App-wide network reachability. Views stuck on an error subscribe via
    /// `.recoversFromOffline` and auto-reload when this flips back online.
    @State private var connectivity: ConnectivityMonitor = .init()

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
            .environment(connectivity)
            // tvOS: measure the true window height here, OUTSIDE the TabView, so a full-bleed hero
            // inside a `.sidebarAdaptable` tab (Home) fills the whole screen instead of its
            // overscan-short tab region (see `\.heroViewportHeight`). No-op on iOS.
            .measuresHeroViewport()
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
                // Structured (no wrapping `Task {}`): the loop is the tail of this
                // `.task`, so it shares the view's cancellation instead of leaking.
                for await _ in dependencies.audioSession.routeChanges {
                    await dependencies.deviceProfileBuilder.invalidate()
                }
            }
            // Republish network reachability into `connectivity` for the app's lifetime. A
            // SEPARATE `.task` so it runs concurrently with the route-change loop above (which
            // never returns); both share the view's cancellation. Drives `.recoversFromOffline`
            // on views stuck in an error state.
            .task { await connectivity.observe() }
    }
}
