import SwiftUI
import ParallaxJellyfin

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(LaunchGate.self) private var launchGate
    @Environment(AppDependencies.self) private var deps
    /// Monotonic token per `isPlayerPresent` edge — see the `.onChange` below.
    @State private var playbackPresenceSeq = 0

    var body: some View {
        @Bindable var router = router
        #if os(tvOS)
        // Eager body-scope read: Observation only tracks properties read DURING
        // body evaluation, and the tvOS cover's `Binding(get:)` closure runs
        // outside it — without this line the tvOS player would never present or
        // dismiss. (iOS reads playback state only via `isPlayerPresent` in the
        // `.disabled` gate below, so RootView re-evaluates twice per playback
        // session — present and teardown — which is cheap: nothing under it churns.)
        let playerRequest = playback.request
        #endif
        // The launch animation plays over the real root from process start; the
        // content beneath it boots (and fetches) as normal during the hold.
        LaunchRevealHost {
            Group {
                switch router.destination {
                case .bootstrapping, .home:
                    // One `RootTabView` for bootstrap + home so finishing `ServerStore.load()`
                    // doesn't tear down tabs mid-flight (that cancelled Home's first request).
                    //
                    // The single screen floor lives HERE, behind the whole tab host — not sprayed
                    // per-screen inside each NavigationStack. It sits under the sidebar/tab-bar glass
                    // too, so the chrome reads as a solid tinted bar (there's nothing but a flat color
                    // to refract anyway). Content stacks on top of this one constant floor, which is
                    // what lets the tvOS detail crossfade dissolve over a background that never moves.
                    Group {
                        #if os(tvOS)
                        FocusRootView()
                        #else
                        // While the player overlay owns the screen, disable the tab host
                        // beneath it: the iPad `.sidebarAdaptable` TabView (a UISplitViewController)
                        // keeps its sidebar gesture live on an ancestor of the overlay, so it was
                        // stealing taps in the left ~sidebar-width band — the double-tap-seek
                        // "left half dead" bug. Nothing under the player should be interactive anyway.
                        // `isPlayerPresent` (not `request`) so the gate holds through the slide-out
                        // teardown, when the player still covers the screen but `request` is already nil.
                        RootTabView()
                            .disabled(playback.isPlayerPresent)
                        #endif
                    }
                    .background(BackgroundField.style.ignoresSafeArea())
                case .login:
                    // Login sits outside `RootTabView`, so it carries its own floor. The source
                    // picker (Jellyfin / SMB) fronts the sign-in form; `LoggedOutRootView` owns
                    // the sheet vs. full-screen presentation per platform.
                    LoggedOutRootView()
                }
            }
        }
        // The launch reveal covers the first HOME boot, not login. A serverless
        // cold launch resolves to login with nothing to reveal, so cut the stage
        // (no story playing behind the sign-in sheet); when a server is finally
        // added (login → home), rearm it so the reveal plays over THAT boot — the
        // same cover a cold launch with a saved server already gets. (Home's own
        // hold release lives in `HomeView`'s load task.)
        .onChange(of: router.destination, initial: true) { previous, destination in
            switch destination {
            case .login:
                launchGate.finish()
            case .home where previous == .login:
                launchGate.rearm()
            case .home, .bootstrapping:
                break
            }
        }
        // A server revoked our access token (HTTP 401 — an admin clearing devices, a server
        // rebuild, the public demo server's nightly reset). Sign that ONE server out and re-route:
        // the row stays in Settings as signed-out with a "Sign In Again" prompt, the other servers
        // are untouched, and `updateForSources` moves the reload token so the sidebar and Home
        // drop its libraries. Without this the app kept showing the server as connected while
        // every request 401'd — no libraries, no error, no way back but removing it by hand.
        //
        // Lives at the root, above `RootTabView`'s `.id(activeServerID)` remount, so the consumer
        // survives the re-route it triggers. Serial by construction: concurrent requests all 401
        // together, and `invalidateSession` returns false for every call after the first.
        .task {
            for await serverID in deps.tokenRejections {
                guard await deps.serverStore.invalidateSession(serverID) else { continue }
                router.updateForSources(await deps.serverStore.sourceSnapshot)
            }
        }
        // Monochrome chrome: no brand accent anywhere. This overrides the system
        // accent for every control (selection, toggles, links) beneath the root.
        .tint(Color.label)
        // iPad's settings sheet lives at the stable root — ABOVE RootTabView's
        // `.id(activeServerID)` remount — so switching/adding a server from inside it (which
        // re-points the router) doesn't tear the open panel down. iPhone uses a Settings tab
        // instead (see RootTabView), so this only ever fires on iPad's sidebar-footer action.
        #if !os(tvOS)
        .sheet(isPresented: $router.presentingSettings) {
            SettingsView(isModal: true)
        }
        #endif
        // The player lives at the stable root — ABOVE RootTabView's
        // `.id(activeServerID)` remount — so a server switch can't force-dismiss it
        // and then re-present the previous server's player from a stale request.
        //
        // iOS: an overlay LAYER, not a `fullScreenCover` — a cover's container is
        // opaque, so the pull-to-dismiss could only ever reveal black above the
        // pulled surface. As a real layer over the live UI, the pull (and the
        // slide-out it hands off to) genuinely uncovers the screen that started
        // playback, like dragging a sheet. tvOS keeps the cover: no pull gesture
        // there, and the cover's focus containment is load-bearing.
        #if os(tvOS)
        .fullScreenCover(item: Binding(
            get: { playerRequest },
            set: { if $0 == nil { playback.dismiss() } }
        )) { request in
            PlayerView(request: request)
        }
        #else
        // Explicit offset-driven layer, NOT `if let` + `.transition` — a
        // transition's placement spring proved clobberable by the player's own
        // mid-flight commits (stuck half-presented, dropped slide-up, cut
        // slide-out). See `PlayerPresentationHost` for the full story.
        .overlay {
            PlayerPresentationHost()
        }
        #endif
        // Switching / adding / signing out a server closes any open player: its
        // content belongs to the previous server's session.
        .onChange(of: router.activeServerID) { _, _ in
            playback.dismiss()
        }
        // SMB thumbnail generation yields the uplink to the player: the full-screen player
        // covers the grid WITHOUT cancelling its cells' `.task`s, so without this hold the
        // frame-grab pipeline keeps streaming over the same link the stream is using.
        // `isPlayerPresent` (not `request`) so the hold spans the teardown grace too.
        // The seq token is minted HERE (MainActor = ordered edges) because the unstructured
        // Tasks below can reach the provider actor out of order — a reordered false-then-true
        // would otherwise latch the hold with no player on screen.
        .onChange(of: playback.isPlayerPresent) { _, present in
            playbackPresenceSeq += 1
            let seq = playbackPresenceSeq
            let provider = deps.mediaArtworkProvider
            Task { await provider.setPlaybackActive(present, seq: seq) }
        }
    }
}
