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
    /// App-wide subtitle appearance. Read by the player overlay (`SubtitleOverlayView`)
    /// and edited from Settings; overlay-only, so it never touches engine-native tracks.
    @State private var subtitlePreferences: SubtitlePreferences = .init()
    /// Whether the Subtitles menu is open — drives the floating preview "lights" overlay.
    @State private var subtitlePreview: SubtitlePreviewState = .init()

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
        // Read the live style HERE — not only inside the window-overlay's escaping closure — so a style
        // change registers a dependency, re-renders this content, and pushes the update into the overlay
        // window in real time (otherwise the preview only refreshes on menu re-entry).
        let previewStyle = subtitlePreferences.style
        return RootView()
            .environment(dependencies)
            .environment(router)
            .environment(playback)
            .environment(launchGate)
            .environment(connectivity)
            .environment(subtitlePreferences)
            .environment(subtitlePreview)
            // The subtitle-preview "lights" float above EVERYTHING and fade in while the Subtitles menu
            // is open — only the cue + dim/spotlight float, not the menu itself. iOS uses a passthrough
            // overlay WINDOW so it clears the iPad Settings form-sheet (an app-root `.overlay` lands
            // behind it); tvOS (Settings is a tab, no sheet) uses a plain overlay to avoid multi-window
            // focus risk.
            #if os(tvOS)
            .overlay {
                // Scope the fade to the overlay's own container, not the whole RootView — a
                // root-level `.animation(value:)` would also animate any unrelated change that
                // happens to land in the same frame the lights toggle.
                ZStack {
                    if subtitlePreview.isActive {
                        SubtitleStageLights(style: previewStyle)
                            .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.45), value: subtitlePreview.isActive)
            }
            #else
            .background(
                WindowOverlay(isPresented: subtitlePreview.isActive) {
                    SubtitleStageLights(style: previewStyle)
                }
            )
            #endif
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
