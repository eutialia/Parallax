import Foundation

/// A read of the whole configured source set, taken in one hop off `ServerStore`.
///
/// The app's router is driven entirely by this rather than by individual store properties. That's
/// deliberate: the previous shape ("active session + a Bool for auxiliary sources") could not
/// express a change to the *set* of sources that left those two alone, and the navigation roots key
/// their library rebuild on the router. Adding a second Jellyfin server is exactly that case — the
/// first server stays active and no SMB source is involved — so nothing re-fired and the new
/// server's libraries only appeared after a relaunch.
public struct SourceSnapshot: Sendable, Hashable {
    /// The active Jellyfin session's id, or nil for a valid SMB-only (or empty) configuration.
    public let activeSessionID: ServerID?
    /// Whether any non-Jellyfin source (SMB today) is configured — the term that makes an
    /// SMB-only config a real home rather than a login dead-end.
    public let hasAuxiliarySources: Bool
    /// Fingerprint of the configured sources: every persisted server id in order, each marked with
    /// whether it currently has a live session. Any add, removal, sign-in, or sign-out changes it,
    /// which is what makes the roots' reload key self-maintaining instead of depending on each
    /// mutation site remembering to bump a counter.
    public let setIdentity: String

    public init(activeSessionID: ServerID?, hasAuxiliarySources: Bool, setIdentity: String) {
        self.activeSessionID = activeSessionID
        self.hasAuxiliarySources = hasAuxiliarySources
        self.setIdentity = setIdentity
    }

    /// Any browsable source at all — a live Jellyfin session OR an auxiliary source.
    public var hasAnySource: Bool { activeSessionID != nil || hasAuxiliarySources }

    /// The pre-load state: no sources known yet. `ServerStore.load()` hasn't resolved, so the roots
    /// must not mistake this for "the user has nothing configured".
    public static let empty = SourceSnapshot(
        activeSessionID: nil,
        hasAuxiliarySources: false,
        setIdentity: ""
    )
}
