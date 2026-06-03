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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(router)
                .environment(playback)
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-run LAN discovery on every foreground. The launch-time
                    // pass races (and usually loses to) the iOS Local Network
                    // permission prompt, and iOS exposes no authorization-status
                    // API to observe the grant directly — so the pragmatic
                    // trigger is "rescan when the scene becomes active again".
                    // start() no-ops while a pass is in flight and dedupes by
                    // server id, so a foreground rescan is cheap and additive.
                    guard newPhase == .active else { return }
                    dependencies.lanDiscovery.start()
                }
                .task {
                    // Kick off LAN discovery first — it triggers the iOS
                    // Local Network permission prompt up front (instead of
                    // mid-sign-in) and populates auto-fill suggestions for
                    // the Add Server flow. Retry across the launch window so a
                    // late permission grant (the first pass usually loses the
                    // race to the prompt) still surfaces the server without a
                    // relaunch; retries stop as soon as one is found.
                    dependencies.lanDiscovery.start(retries: 3, retryInterval: .seconds(2))
                    do {
                        try await dependencies.serverStore.load()
                    } catch {
                        ParallaxCore.Log.persistence.error("ServerStore.load failed: \(error.localizedDescription)")
                    }
                    router.updateForCurrentSession(await dependencies.serverStore.active)

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
}
