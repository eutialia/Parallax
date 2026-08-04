import Foundation
import ParallaxCore

/// The explicit track picks a RE-resolve carries, for when the user switched
/// audio or subtitles mid-playback and the server has to rebuild the stream
/// around that choice. `nil` at the resolve call site means "first play — let the
/// server pick from the user's own language preferences".
///
/// `mediaSourceID` is not optional on purpose. Jellyfin only applies
/// `AudioStreamIndex`/`SubtitleStreamIndex` to the media source they were sent
/// WITH: its PlaybackInfo handler compares the request's media-source id against
/// each source it is about to describe and, when they don't match, drops both
/// indices on the floor without an error. A selection without a source id is
/// therefore not a weaker request, it's a silently ignored one — so the type
/// makes it impossible to build.
public struct StreamSelection: Sendable, Hashable {
    /// The media source the indices below belong to — `ResolvedPlayback.mediaSourceID`
    /// of the session being replaced.
    public let mediaSourceID: String
    /// Source stream index for audio; `nil` keeps the server's default.
    public let audioStreamIndex: Int?
    /// Source stream index for subtitles. `-1` is Jellyfin's "no subtitle"
    /// sentinel — distinct from `nil`, which asks for the server default again.
    public let subtitleStreamIndex: Int?
    /// The picked subtitle is an image format, so the only way to show it is to
    /// have the server paint it into the video. Turns off the stream-copy offer:
    /// a copied video stream carries no burned-in picture, so leaving copy on lets
    /// the server answer a burn-in request with a stream it can't burn anything
    /// into. Mirrors what the official web client sends for the same pick.
    public let burnsInSubtitle: Bool

    public init(
        mediaSourceID: String,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        burnsInSubtitle: Bool = false
    ) {
        self.mediaSourceID = mediaSourceID
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.burnsInSubtitle = burnsInSubtitle
    }
}
