import CoreMedia
import ParallaxPlayback

/// What the next engine-reusing transcode reload must honor.
///
/// A mid-session reload takes seconds, and the HUD stays live through it — so a seek, an
/// audio pick and a subtitle pick can all land while one is in flight. They used to reach
/// three different roads (`pendingReanchorTarget`, and two drop-don't-queue guards) and the
/// loser was silently dropped. Here they are three ORTHOGONAL dimensions of one intent: the
/// drain reloads once with whatever is standing, so any combination costs exactly one
/// re-resolve.
///
/// Each dimension is newest-wins, because a pick the user has already replaced is not worth
/// a reload. `previous` is the opposite: it is the selection to RESTORE if the reload never
/// lands, so it must survive every later pick — merging keeps the OLDEST previous and the
/// NEWEST pick.
struct PendingReload: Equatable {
    /// An audio pick waiting on the reload.
    struct AudioChange: Equatable {
        var pick: AudioTrack
        var previous: AudioTrack?
    }

    /// A subtitle pick waiting on the reload. Both halves are optional and mean different
    /// things: a nil `pick` is Off — the dimension's third state, and a real intent — while a
    /// nil `previous` is "nothing was selected to go back to".
    struct SubtitleChange: Equatable {
        var pick: SubtitleTrack?
        var previous: SubtitleTrack?
        /// The failure to surface once THIS change lands. Only the rollback of a burn-in the
        /// server declined carries one: the scrim cannot go up where the decline is found,
        /// because the rollback clears `trackSwitchFailure` optimistically like any other
        /// pick. Riding the intent rather than the drain is what keeps it off whichever
        /// iteration happens to run next — a pick the user made during the rollback drops it.
        var reportOnLand: PlayerViewModel.TrackSwitchFailure?
    }

    /// Where the reload must resume. Nil means "wherever playback already is".
    var position: CMTime?
    var audio: AudioChange?
    var subtitle: SubtitleChange?

    /// Nothing standing — the drain's loop condition. Note an Off subtitle pick is NOT
    /// empty: `subtitle` is set with a nil `pick`.
    var isEmpty: Bool { position == nil && audio == nil && subtitle == nil }

    mutating func merge(position target: CMTime) {
        position = target
    }

    /// A standing change keeps its `previous` (the selection to restore) and takes the new pick.
    mutating func merge(audio pick: AudioTrack, previous: AudioTrack?) {
        if audio == nil {
            audio = AudioChange(pick: pick, previous: previous)
        } else {
            audio?.pick = pick
        }
    }

    /// `merge(audio:previous:)`'s twin, plus one rule of its own: a new pick drops any
    /// `reportOnLand` the standing change carried, because the user has moved off the track
    /// that record is about.
    mutating func merge(subtitle pick: SubtitleTrack?, previous: SubtitleTrack?) {
        if subtitle == nil {
            subtitle = SubtitleChange(pick: pick, previous: previous)
        } else {
            subtitle?.pick = pick
            subtitle?.reportOnLand = nil
        }
    }
}
