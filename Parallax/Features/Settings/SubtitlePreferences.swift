import Observation
import ParallaxCore
import ParallaxPlayback

/// App-wide subtitle appearance, bridged from the persisted `SettingsStore` (a
/// `ParallaxCore` actor over `UserDefaults`) into an `@Observable` the player overlay
/// and the Settings screen both read.
///
/// **Overlay-only by design.** These values reach `SubtitleOverlayView` (the client
/// renderer for sidecar/external SRT & VTT) — they never reach the engine-native
/// renderers (libass / AVKit), which have no styling API on iOS. So a user's size /
/// color / position / font choice can never touch (or break) a self-positioned
/// ASS / CJK track: the override has no path to it. See the subtitle-settings spec.
@MainActor
@Observable
final class SubtitlePreferences {
    /// Reverse-DNS key, JSON-encoded into `UserDefaults` like every other setting.
    /// `defaultValue: .standard` means a fresh install renders exactly as before.
    static let key = SettingKey<SubtitleStyle>(name: "Parallax.subtitleStyle", defaultValue: .standard)

    private let store: SettingsStore

    /// The live style. Starts at `.standard` (today's look) until the persisted value
    /// loads — a near-instant `UserDefaults` read whose default already equals
    /// `.standard`, so there is no visible flash on launch.
    private(set) var style: SubtitleStyle = .standard

    /// Set the instant the user makes their first edit, so the initial async `load()` — which may
    /// still be in flight behind its actor hop — can't resume late and clobber that edit with the
    /// stale persisted value.
    private var didEdit = false

    /// Serializes persistence: each write awaits the previous one, so rapid edits land in submission
    /// order and the LAST edit wins. Unstructured per-call `Task`s would race to the actor and could
    /// persist an older style, silently reverting the user's last change on the next launch.
    private var writeChain: Task<Void, Never>?

    /// A private default `SettingsStore()` is intentional: the store is stateless over
    /// `UserDefaults.standard`, so this instance reads/writes the same bytes as the one
    /// in `AppDependencies` — no shared instance or cache coordination needed.
    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        Task { await load() }
    }

    func load() async {
        let persisted = await store.value(for: Self.key)
        // A user edit during the load wins — don't overwrite it with what was on disk at launch.
        guard !didEdit else { return }
        style = persisted
    }

    /// Apply + persist. Optimistic: updates the observable immediately so the UI reflects
    /// the change this frame, then writes through to `UserDefaults` in order off the actor.
    func update(_ newStyle: SubtitleStyle) {
        guard newStyle != style else { return }
        didEdit = true
        style = newStyle
        let previous = writeChain
        writeChain = Task { [store] in
            await previous?.value          // strict submission order → last write wins
            try? await store.set(newStyle, for: Self.key)
        }
    }
}
