import Observation
import ParallaxCore
import ParallaxPlayback

/// App-wide subtitle appearance, bridged from the persisted `SettingsStore` (a
/// `ParallaxCore` actor over `UserDefaults`) into an `@Observable` the player overlay
/// and the Settings screen both read.
///
/// **Client-overlay-only by design.** These values reach the client sidecar renderer
/// (`SubtitleOverlayView` → `ParallaxSubtitles`) — never the engine-native renderers
/// (VLC's internal libass for embedded tracks / AVKit legible), which have no styling
/// API on iOS. For sidecar tracks the reach is format-aware: SRT/VTT (no authored look
/// of their own) always take this style; authored ASS/SSA keeps its creator styling
/// unless `overrideAuthoredStyles` is explicitly switched on.
@MainActor
@Observable
final class SubtitlePreferences {
    /// Reverse-DNS key, JSON-encoded into `UserDefaults` like every other setting.
    /// `defaultValue: .standard` means a fresh install renders exactly as before.
    static let key = SettingKey<SubtitleStyle>(name: "Parallax.subtitleStyle", defaultValue: .standard)

    /// Whether the user's style also replaces the AUTHORED styling of ASS/SSA tracks
    /// (fansub colors, fonts, per-speaker palettes). Default OFF: subtitles show what
    /// their creators intended, and the style above only governs formats that carry no
    /// styling of their own.
    static let overrideAuthoredKey = SettingKey<Bool>(
        name: "Parallax.subtitleOverrideAuthoredStyles", defaultValue: false
    )

    private let store: SettingsStore

    /// The live style. Starts at `.standard` (today's look) until the persisted value
    /// loads — a near-instant `UserDefaults` read whose default already equals
    /// `.standard`, so there is no visible flash on launch.
    private(set) var style: SubtitleStyle = .standard

    /// Live value of `overrideAuthoredKey`. Same load/edit discipline as `style`.
    private(set) var overrideAuthoredStyles = false

    /// Set the instant the user makes their first edit, so the initial async `load()` — which may
    /// still be in flight behind its actor hop — can't resume late and clobber that edit with the
    /// stale persisted value.
    private var didEdit = false
    private var didEditOverrideAuthored = false

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
        let persistedOverride = await store.value(for: Self.overrideAuthoredKey)
        // A user edit during the load wins — don't overwrite it with what was on disk at launch.
        if !didEdit { style = persisted }
        if !didEditOverrideAuthored { overrideAuthoredStyles = persistedOverride }
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

    /// Same optimistic apply + ordered write-through as `update(_:)`, for the
    /// authored-styles override toggle.
    func setOverrideAuthoredStyles(_ enabled: Bool) {
        guard enabled != overrideAuthoredStyles else { return }
        didEditOverrideAuthored = true
        overrideAuthoredStyles = enabled
        let previous = writeChain
        writeChain = Task { [store] in
            await previous?.value
            try? await store.set(enabled, for: Self.overrideAuthoredKey)
        }
    }
}
