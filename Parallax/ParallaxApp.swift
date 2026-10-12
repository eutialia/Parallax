//
//  ParallaxApp.swift
//  Parallax
//
//  Created by Linghao Hsu on 2026-05-26.
//

import SwiftUI
import os
import AVFoundation
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxSubtitles

@main
struct ParallaxApp: App {
    // Vends `OrientationController`'s mask to UIKit — the only orientation hook a SwiftUI
    // lifecycle app reaches. iOS only: tvOS has no interface orientation.
    #if !os(tvOS)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    #endif

    @State private var app: AppModel
    @State private var dependencies: AppDependencies
    /// Whether the Subtitles menu is open — drives the floating preview "lights" overlay.
    @State private var subtitlePreview: SubtitlePreviewState = .init()

    init() {
        // FIRST, before dependencies: the retained log has to be open before anything it might want
        // to record runs, and arming `CrashSentinel` early is the difference between a crash during
        // startup leaving a stack behind and leaving nothing.
        DiagnosticsLog.start()
        AppDiagnostics.lifecycle.mark("launch")

        // Both subtitle renderers learn the bundled fonts ahead of the first pick: libvlc's
        // Darwin text renderer resolves `--freetype-font=<family>` through CoreText, which
        // cannot see a font that only sits in the bundle, and our libass pays its one-time
        // `ass_add_font` bootstrap wherever it is first asked. Both are idempotent and off
        // the main thread; nothing awaits them — the first subtitle draw is a session away.
        Task.detached(priority: .utility) {
            SubtitleFontRegistration.registerIfNeeded()
            // VLC's INTERNAL libass is a third consumer with its own rule: its default
            // family is the hardcoded "Helvetica Neue" and it takes a directory, not a
            // file list. `VLCSubtitleFonts` materializes that directory per design.
            VLCSubtitleFonts.prepareIfNeeded()
            // The retired `SubtitleFontLocator` left tens of MB of extracted system faces
            // behind; nothing has read them since it was deleted.
            VLCSubtitleFonts.pruneRetiredCaches()
        }
        SubtitleFontBundle.warmUp()

        let app = AppModel(environment: .live())
        _app = State(initialValue: app)
        _dependencies = State(initialValue: AppDependencies(services: app.services))
    }

    var body: some Scene {
        WindowGroup {
            appRoot
        }
    }

    private var appRoot: some View {
        // Read the live style HERE — not only inside the window-overlay's escaping closure — so a style
        // change registers a dependency, re-renders this content, and pushes the update into the overlay
        // window in real time (otherwise the preview only refreshes on menu re-entry).
        let previewStyle = app.subtitlePreferences.style
        return RootView()
            .environment(app)
            .environment(dependencies)
            .environment(app)
            .environment(app.router)
            .environment(app.playback)
            .environment(app.userDataActions)
            .environment(app.launchGate)
            .environment(app.subtitlePreferences)
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
            // Unconditional scene-phase record for the retained log — see the modifier for why the
            // per-screen refresh modifiers can't stand in for it.
            .recordsScenePhaseForDiagnostics()
            .forwardsScenePhase(to: app.lifecycle)
            .task {
                await app.bootstrap()

                #if DEBUG
                // Scripted sign-in for simulator screenshot runs (same family as
                // `-openSettingsTab`): `-uiSignIn <serverURL> <username> [password]`
                // drives the exact SessionManager path the Connect button uses,
                // then re-routes onto the signed-in tabs.
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "-uiSignIn"),
                   args.indices.contains(i + 2),
                   let serverURL = URL(string: args[i + 1]) {
                    let password = args.indices.contains(i + 3) && !args[i + 3].hasPrefix("-")
                        ? args[i + 3] : ""
                    do {
                        try await app.signIn(server: serverURL, username: args[i + 2], password: password)
                    } catch {
                        ParallaxCore.Log.persistence.error("uiSignIn failed: \(error.localizedDescription)")
                    }
                }

                // Playback Lab: `-playbackLab <config.json path>` runs a scripted,
                // UI-free SMB playback session for autonomous debugging — see
                // PlaybackLabRunner.
                if let labRunner = PlaybackLabRunner.makeIfRequested(
                    dependencies: dependencies, playback: app.playback
                ) {
                    await labRunner.run()
                }
                #endif
            }
            // The app-lifetime flows: token rejections, the launch reveal following the route,
            // closing the player on a server switch, reachability. Its own `.task` because it
            // never returns; it shares the view's cancellation.
            .task { await app.run() }
            // Rebuild the device profile on the next resolve whenever HDR eligibility changes
            // (display connect/disconnect, Low Power Mode, other system resource shifts).
            // `AVPlayer.eligibleForHDRPlayback` is dynamic and explicitly NOT KVO-observable;
            // this notification is Apple's supported way to learn it moved. Per the spec,
            // in-flight playback is intentionally NOT interrupted. A SEPARATE `.task` (mirrors
            // the one above) so it shares the view's cancellation instead of leaking.
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: AVPlayer.eligibleForHDRPlaybackDidChangeNotification
                ) {
                    await dependencies.deviceProfileBuilder.invalidate()
                }
            }
    }
}
