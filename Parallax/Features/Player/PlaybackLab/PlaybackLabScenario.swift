#if DEBUG
import Foundation

/// A scripted, UI-free playback session for autonomous debugging: which SMB
/// server to add, which file in the lab folder to play, and a timeline of
/// player commands to execute. Decoded from the JSON file whose host path is
/// passed via the `-playbackLab <path>` launch argument (simulator apps can
/// read host paths directly, so credentials stay in a git-ignored local file).
struct PlaybackLabScenario: Codable, Sendable {

    struct Server: Codable, Sendable {
        let host: String
        let username: String
        let password: String
        /// Optional in JSON; empty means no domain, matching the manual add flow.
        let domain: String?
        let share: String
    }

    /// One timeline step. A plain struct keyed by `cmd` (not a Codable enum) so
    /// scenario JSON stays hand-editable: `{"cmd": "scrub", "toSeconds": 120}`.
    ///
    /// Commands:
    /// - `waitPlaying` (`timeoutSeconds`, default 60): block until the player
    ///   reaches `.playing`; a `.failed` phase aborts the run.
    /// - `wait` (`seconds`): let playback run untouched.
    /// - `play` / `pause`: explicit transport, via the same `setPlaying` path
    ///   the HUD button uses.
    /// - `seek` (`toSeconds`) / `skip` (`bySeconds`): transport-preserving
    ///   in-stream seek — the double-tap-skip family.
    /// - `scrub` (`toSeconds`): full UI-fidelity drag sandwich — scrub latch,
    ///   engine pause, commit seek, latch release — because the pause→seek→play
    ///   shape reproduces bugs a plain seek does not.
    /// - `finish`: dismiss the player and end the run.
    struct Step: Codable, Sendable {
        let cmd: String
        let seconds: Double?
        let toSeconds: Double?
        let bySeconds: Double?
        let timeoutSeconds: Double?
    }

    let server: Server
    /// Share-relative folder holding the lab media, e.g. "Debug" when the
    /// share itself is "Media" and files live at Media/Debug.
    let path: String
    /// File name inside `path` to play.
    let file: String
    let timeline: [Step]
}
#endif
