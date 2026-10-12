import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

/// The player's track menus as functions of what the server resolved and what the engine
/// reports: which rows exist, what they are called, and who draws each subtitle.
enum PlayerTrackMenus {
    /// The direct-play subtitle menu.
    ///
    /// **Jellyfin: the row's renderer decides its id, per stream.**
    /// `PlaybackInfoService` builds a sidecar URL for every TEXT stream — embedded
    /// ones included — so those become `.jellyfinStream` rows, fetched and drawn by
    /// our own libass, taking the user's settings and looking identical on both
    /// engines. An IMAGE stream has no sidecar, so it keeps the ENGINE's inventory row
    /// (`.vlc`/`.avKitOption`, joined to the server's metadata by
    /// `JellyfinTrackMatcher`) and the engine draws the bitmaps locally, for free.
    /// Only an image stream the engine can't be matched to falls back to a server
    /// burn-in pick — a full re-encode, so it is the last resort, not the default.
    ///
    /// **SMB keeps the engine's inventory**: there is no extraction endpoint for a
    /// local container, so its embedded tracks can only be engine-rendered. The
    /// filename-matched sidecars are appended.
    static func directPlaySubtitleMenu(
        engineTracks: [SubtitleTrack],
        resolved: ResolvedPlayback?,
        smbExternals: [SubtitleTrack]
    ) -> DirectPlaySubtitleMenu {
        let streams = resolved?.mediaStreams.filter { $0.kind == .subtitle } ?? []
        guard let resolved, !streams.isEmpty else {
            return DirectPlaySubtitleMenu(
                tracks: engineTracks.map(normalizedEmbeddedSubtitle)
                    + (resolved.map(externalSubtitleTracks) ?? smbExternals),
                rowIDsByStream: [:]
            )
        }
        let engineByStream = engineTracksByStreamIndex(
            engineTracks: engineTracks,
            streams: streams,
            defaultStreamIndex: resolved.defaultSubtitleStreamIndex
        )
        let tracks = streams.map { stream in
            if resolved.subtitleStreamURLs[stream.index] != nil {
                return subtitleTrack(from: stream)          // text → we draw it
            }
            if let engineTrack = engineByStream[stream.index] {
                return engineRenderedSubtitle(stream: stream, engineTrack: engineTrack)
            }
            return subtitleTrack(from: stream)              // no renderer → server burn-in
        }
        return DirectPlaySubtitleMenu(
            tracks: tracks,
            // First writer wins, for the same reason `engineTracksByStreamIndex` says so:
            // a server that repeats a stream index is malformed, and the later row is no
            // better a guess than the first.
            rowIDsByStream: Dictionary(zip(streams.map(\.index), tracks.map(\.id))) { first, _ in first }
        )
    }

    /// The direct-play menu plus the join a *server preference* needs.
    ///
    /// A row's id names its RENDERER (`.jellyfinStream` for one we draw, `.vlc` /
    /// `.avKitOption` for one the engine draws), so nothing in the row itself says
    /// which server stream it came from. `rowIDsByStream` is that answer, recorded
    /// where the rows are built rather than re-derived later — a second derivation
    /// could disagree with the menu, and then a default would tick a row that isn't
    /// there. Empty on SMB/local, which has no server stream list at all.
    struct DirectPlaySubtitleMenu {
        let tracks: [SubtitleTrack]
        let rowIDsByStream: [Int: TrackID]
    }

    /// Whether the ENGINE is what draws this session's subtitles — the read side of
    /// `PlayableAsset.engineSubtitlesDisabled`. Always true off-Jellyfin (SMB/local:
    /// the engine's inventory is all there is).
    static func engineRendersSubtitles(_ resolved: ResolvedPlayback?) -> Bool {
        guard let resolved else { return true }
        return !resolved.clientRendersAllSubtitles
    }

    /// Joins the engine's own subtitle inventory to the server's stream list, so an
    /// image stream can be offered under the engine track that actually renders it.
    ///
    /// Deliberately matched against ALL subtitle streams, not just the image ones:
    /// narrowing the candidates would let a text engine track match the lone image
    /// stream by elimination and hand the menu the wrong id. `JellyfinTrackMatcher`
    /// returns nil for an ambiguous join (two same-language streams), which costs the
    /// image sub its engine row and falls it back to burn-in — degraded, never wrong.
    static func engineTracksByStreamIndex(
        engineTracks: [SubtitleTrack],
        streams: [MediaStreamInfo],
        defaultStreamIndex: Int?
    ) -> [Int: SubtitleTrack] {
        var byStream: [Int: SubtitleTrack] = [:]
        for track in engineTracks {
            guard let stream = JellyfinTrackMatcher.matchedSubtitleStream(
                languageCode: track.languageCode,
                trackCount: engineTracks.count,
                streams: streams,
                defaultStreamIndex: defaultStreamIndex
            ) else { continue }
            // First writer wins: two engine tracks resolving to one stream is an
            // ambiguous join, and the later one is no better a guess than the first.
            if byStream[stream.index] == nil { byStream[stream.index] = track }
        }
        return byStream
    }

    /// A menu row for a stream the ENGINE renders: the engine's id (that's what
    /// `setSubtitleTrack` needs) under the server's naming (that's what a person
    /// picks by). Not `isBurnedIn` — nothing is re-encoded; the bitmaps are composited
    /// locally.
    static func engineRenderedSubtitle(
        stream: MediaStreamInfo,
        engineTrack: SubtitleTrack
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: engineTrack.id,
            displayName: stream.menuLabel,
            languageCode: stream.language ?? engineTrack.languageCode,
            isForced: stream.isForced,
            detailLabel: TrackDisplay.subtitleFormatName(stream.codec),
            isExternal: stream.isExternal,
            isSDH: stream.isHearingImpaired,
            isBurnedIn: false
        )
    }

    /// External (sidecar) text subtitles from the server, as direct-play menu entries
    /// with `.jellyfinStream` ids. All sidecar text renders client-side
    /// (`SubtitleOverlayView`, fed by `loadSidecarSubtitle`, requesting ass/ssa/srt
    /// verbatim so authored styling survives) rather than through the engine — VLC
    /// can't shape sidecar text on iOS, and embedded subs already come from the
    /// engine's own inventory. Image subs are excluded here by policy: they go
    /// through server burn-in. Labels come from the server, so they read "English"
    /// etc. instead of VLC's generic "Track N".
    static func externalSubtitleTracks(from resolved: ResolvedPlayback) -> [SubtitleTrack] {
        resolved.mediaStreams
            .filter { $0.kind == .subtitle && $0.isExternal && !$0.isImageSubtitle }
            .map(subtitleTrack(from:))
    }

    /// Sidecar formats the client-side renderer (`ParallaxSubtitles`) ingests —
    /// authored ASS/SSA verbatim, SRT/VTT via its converter. Case-insensitive
    /// extension check.
    static let renderableSidecarExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// SMB analog of `externalSubtitleTracks(from resolved:)` — there's no `resolved`
    /// stream list on the SMB path, only the filename-matched `[index: URL]` map + the
    /// resolver's `[index: label]`. Builds the same `.jellyfinStream`-id, client-rendered
    /// external tracks (so `selectSubtitleTrack` → `activateSidecarSubtitle` → the overlay
    /// path works identically) with the resolver's labels and the file extension as detail.
    /// Ordered by index for a stable menu.
    ///
    /// Filtered to `renderableSidecarExtensions` so a matched sibling in a format the
    /// renderer can't ingest (e.g. `.sub`/`.idx` image subs) never becomes a menu entry
    /// that draws nothing; `subtitleURLs` itself stays unfiltered.
    static func externalSubtitleTracks(urls: [Int: URL], labels: [Int: String]) -> [SubtitleTrack] {
        let built = urls.keys.sorted().compactMap { index -> (track: SubtitleTrack, raw: String)? in
            guard let url = urls[index],
                  renderableSidecarExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            let format = url.pathExtension.uppercased()
            let detail = format.isEmpty ? "External" : "\(format) · External"
            // Translate the filename-derived label ("zh.hi", "en.forced") into the
            // same naming tier the Jellyfin path uses: localized language name +
            // SDH/forced flags. Labels with no recognised tokens ("Default", a
            // release-group tag) pass through verbatim. The language tag also
            // makes SMB sidecars visible to remembered-language matching.
            let raw = labels[index] ?? "Subtitle \(index + 1)"
            let info = SubtitleLabelInfo(label: raw)
            let track = SubtitleTrack(
                id: .jellyfinStream(index),
                displayName: info.displayName(fallback: raw),
                languageCode: info.languageTags.first,
                isForced: info.isForced,
                detailLabel: detail,
                isExternal: true,
                isSDH: info.isSDH
            )
            return (track, raw)
        }
        // Ambiguity guard: translation can collapse distinct labels onto one menu
        // row ("en" and "en.full" both read "English") — when name AND detail
        // collide, those tracks fall back to their raw labels; a pretty name the
        // user can't tell apart is worse than the filename tag it replaced.
        let rowCounts = Dictionary(
            built.map { (key: $0.track.displayName + "|" + ($0.track.detailLabel ?? ""), value: 1) },
            uniquingKeysWith: +
        )
        return built.map { track, raw in
            guard track.displayName != raw,
                  rowCounts[track.displayName + "|" + (track.detailLabel ?? ""), default: 0] > 1
            else { return track }
            return SubtitleTrack(
                id: track.id,
                displayName: raw,
                languageCode: track.languageCode,
                isForced: track.isForced,
                detailLabel: track.detailLabel,
                isExternal: track.isExternal,
                isSDH: track.isSDH
            )
        }
    }

    /// VLC's untitled-track fallback names, lowercased → the format name for the
    /// detail line. An MKV subtitle track with no authored title surfaces from
    /// libvlc as its codec description ("ASS", "SubRip", "UTF-8"…) — not a name a
    /// person picks a track by. When the track carries a language, swap in the
    /// localized language name (the same tier the Jellyfin path's `menuLabel`
    /// uses) and demote the format to the detail line. Authored titles ("Full
    /// Subs - [Japanese]") never match this table and pass through verbatim.
    static let embeddedFormatFallbackNames: [String: String] = [
        "ass": "ASS", "ssa": "SSA", "srt": "SRT", "subrip": "SRT",
        "utf-8": "SRT", "utf8": "SRT", "vtt": "VTT", "webvtt": "VTT",
        "pgs": "PGS", "hdmv pgs": "PGS", "vobsub": "VobSub",
        "dvd subtitles": "VobSub", "dvb subtitles": "DVB",
        "tx3g": "Timed Text", "mov_text": "Timed Text", "t.140": "Timed Text",
        "microdvd": "SUB",
    ]

    /// Display normalization for ENGINE-inventoried (embedded) subtitle tracks —
    /// the engine reports raw container metadata; naming policy lives here.
    /// Only rewrites tracks whose name is a codec-fallback (table above) or a
    /// generic "Track N"/"Subtitle N" AND that carry a language code; everything
    /// else — authored titles, or fallbacks with no language to name — is kept.
    static func normalizedEmbeddedSubtitle(_ track: SubtitleTrack) -> SubtitleTrack {
        let lowered = track.displayName
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let format = Self.embeddedFormatFallbackNames[lowered]
        let isGenericNumbered = ["track", "subtitle"].contains { prefix in
            guard lowered.hasPrefix(prefix) else { return false }
            let rest = lowered.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
        guard format != nil || isGenericNumbered,
              let language = TrackDisplay.languageName(track.languageCode) else {
            return track
        }
        return SubtitleTrack(
            id: track.id,
            displayName: language,
            languageCode: track.languageCode,
            isForced: track.isForced,
            // An engine track that already carries a detail (AVKit tracks matched to
            // Jellyfin streams) keeps it — only VLC's nil gets the derived one.
            detailLabel: track.detailLabel ?? format.map { "\($0) · Embedded" } ?? "Embedded",
            isExternal: track.isExternal,
            isSDH: track.isSDH,
            isBurnedIn: track.isBurnedIn
        )
    }

    /// Maps a server subtitle stream to a menu `SubtitleTrack` with a `.jellyfinStream` id
    /// (fed straight back to the server as `SubtitleStreamIndex` / to the sidecar loader).
    /// Shared by the transcode menu (all text subs, plus opt-in image subs) and the
    /// direct-play external-subs append (external TEXT only — `externalSubtitleTracks`
    /// filters image subs out before this ever sees one) so the two never drift in how
    /// a track is labeled.
    static func subtitleTrack(from stream: MediaStreamInfo) -> SubtitleTrack {
        // Image subs only ever reach here via the transcode menu, where picking one
        // burns it into the video server-side instead of playing as "Embedded"/
        // "External" — the format alone is the detail line (what it's made of);
        // the "Burn-in" badge (below, `isBurnedIn`) carries the consequence, same
        // split as the audio menu's codec detail + "→ AAC" transcode badge.
        let detail = stream.isImageSubtitle
            ? TrackDisplay.subtitleFormatName(stream.codec)
            : stream.trackDetailLabel
        return SubtitleTrack(
            id: .jellyfinStream(stream.index),
            displayName: stream.menuLabel,
            languageCode: stream.language,
            isForced: stream.isForced,
            detailLabel: detail,
            isExternal: stream.isExternal,
            isSDH: stream.isHearingImpaired,
            isBurnedIn: stream.isImageSubtitle
        )
    }
}
