import Foundation

/// `h:mm:ss` / `m:ss` playback clock. Shared by the player chrome and the
/// progress bar so they format identically.
nonisolated func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let whole = Duration.seconds(total)
    if total >= 3600 {
        return whole.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 0)))
    }
    return whole.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 0)))
}
