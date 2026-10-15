import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

extension AppModel {
    /// The player's whole session, for as long as the calling task lives: builds the player for
    /// a presenter request, starts playback, closes the presenter when playback completes with
    /// nowhere to advance, and closes the model when the task is cancelled, whoever closed the
    /// player. Returns once the model has stopped, and only then counts the session as ended.
    /// `install` receives the model before playback starts, so the view renders the loading
    /// phase from the first beat. A request dismissed while the player was being built never
    /// starts.
    ///
    /// `subtitleSurface` is sampled once per session, at asset construction, for the engine's
    /// subtitle sizing.
    public func runPlayer(
        for request: PlaybackPresenter.Request,
        subtitleSurface: @escaping @MainActor () -> SubtitleSurface,
        install: (PlayerViewModel) -> Void
    ) async {
        let vm = switch request.target {
        case .smb(let item, let ref):
            makeSMBPlayer(item: item, ref: ref, subtitleSurface: subtitleSurface)
        case .detail(_, let session, _), .itemID(_, let session, _):
            await makeJellyfinPlayer(session: session, subtitleSurface: subtitleSurface)
        }
        guard !Task.isCancelled, playback.request?.id == request.id else { return }
        // The dismissals that never reach the player's own close button (the tvOS cover
        // dismissing itself, a server switch, the debug lab) still fence and end audio instead of
        // playing on through the slide-out. Weak: the presenter outlives every session.
        playback.setExitHandler(for: request.id) { [weak vm] in vm?.beginExit() }
        install(vm)
        switch request.target {
        case .smb(let item, let ref):
            await vm.start(resolvingSMB: { [resolver = services.smbPlaybackResolver] in
                try await resolver.resolve(item, ref: ref)
            })
        case .detail(let detail, _, let fromBeginning):
            await vm.start(item: detail, fromBeginning: fromBeginning)
        case .itemID(let itemID, _, let fromBeginning):
            await vm.start(itemID: itemID, fromBeginning: fromBeginning)
        }
        // A movie or a series finale that played to its end closes the player, the same way
        // the Close chevron does; episodes auto-advance instead and never complete. The
        // session then lives on until the host unmounts the player.
        for await done in Observations({ vm.playbackDidComplete }) where done && playback.request?.id == request.id {
            playback.dismiss()
        }
        await vm.close()
        endedPlayerSessions += 1
    }

    /// A server-less player reporting to no one, which resolves the file under the veil.
    private func makeSMBPlayer(
        item: Item, ref: SMBServerRef, subtitleSurface: @escaping @MainActor () -> SubtitleSurface
    ) -> PlayerViewModel {
        // Sidecar subtitle URLs are `smb://` on BOTH SMB routes (the bridge serves only the video
        // file), which an HTTP fetch can't open — route the SMB scheme through the resolver
        // (Keychain stays out of the player) and everything else over HTTP.
        let resolver = services.smbPlaybackResolver
        let session = services.urlSession
        let timeout = services.subtitleFetchTimeout
        let artworkProvider = services.mediaArtworkProvider
        return PlayerViewModel(
            deviceProfileBuilder: services.deviceProfileBuilder,
            clock: clock,
            playbackInfo: NoOpPlaybackReporting(),
            resolve: { _, _, _, _ in
                // Unreachable on the SMB path — `start(resolvingSMB:)` delegates to
                // `start(smbItem:)`, which never calls the Jellyfin resolve.
                throw AppError.playback(.unsupportedFormat)
            },
            engineFactory: services.playbackEngineFactory,
            audioSession: services.audioSession,
            nowPlaying: services.makeNowPlaying(),
            subtitleFetch: { url in
                if url.scheme == "smb" {
                    return await resolver.subtitleData(for: url, ref: ref).map(SubtitleFetchOutcome.data) ?? .rejected
                }
                return await Self.fetchSubtitle(url, over: session, timeout: timeout)
            },
            smbResumeStore: services.smbResumeStore,
            // SMB-only: live-session frame grab → `MediaArtworkProvider` cache. Duration is
            // threaded from the player at call time (~8s in); the WAN I/O skip and the cache-key
            // recipe both stay inside the provider.
            backfillThumbnail: { duration, captureFramePerformsIO, captureFrame in
                await artworkProvider.backfillThumbnail(
                    item: item, ref: ref, duration: duration,
                    captureFramePerformsIO: captureFramePerformsIO, captureFrame: captureFrame
                )
            },
            subtitleStyle: subtitleStyleProvider,
            subtitleSurface: subtitleSurface,
            engineSubtitleFonts: services.engineSubtitleFonts,
            prepareDisplay: services.prepareDisplay
        )
    }

    /// The per-session factories (playback info, library repo) are resolved here, once the
    /// session exists, so nothing captures them before.
    private func makeJellyfinPlayer(
        session: Session, subtitleSurface: @escaping @MainActor () -> SubtitleSurface
    ) async -> PlayerViewModel {
        let info = await services.playbackInfoFactory(session)
        let repo = await services.jellyfinLibraryRepoFactory(session)
        let urlSession = services.urlSession
        let timeout = services.subtitleFetchTimeout
        return PlayerViewModel(
            deviceProfileBuilder: services.deviceProfileBuilder,
            clock: clock,
            playbackInfo: info,
            resolve: { id, caps, start, selection in
                try await info.resolve(item: id, capabilities: caps, startTime: start, selection: selection)
            },
            engineFactory: services.playbackEngineFactory,
            audioSession: services.audioSession,
            nowPlaying: services.makeNowPlaying(),
            fetchDetail: { try await repo.detail(for: $0) },
            subtitleFetch: { await Self.fetchSubtitle($0, over: urlSession, timeout: timeout) },
            rememberTrackSelection: { await info.rememberTrackSelection($0) },
            fetchSegments: { (try? await repo.mediaSegments(for: $0)) ?? [] },
            fetchAdjacent: { (try? await repo.adjacentEpisodes(seriesID: $0, episodeID: $1)) ?? .none },
            fetchDelivery: { await info.transcodingDelivery(playSessionID: $0) },
            smbResumeStore: services.smbResumeStore,
            subtitleStyle: subtitleStyleProvider,
            subtitleSurface: subtitleSurface,
            engineSubtitleFonts: services.engineSubtitleFonts,
            prepareDisplay: services.prepareDisplay,
            // Poster bytes for the scrub bar's accent hue. Through the session's own image
            // pipeline, not a bare URLSession: the image endpoints reject anonymous reads on an
            // auth-required server, and the pipeline is the one thing that carries the token. It
            // shares the pipeline, that header, and the cache store with every poster tile — but
            // not their cache ENTRIES, since `maxWidth` is part of Nuke's key and this asks for a
            // thumbnail nothing else requests. `thumbnailMaxPixel` is the whole request: an
            // accent needs a hue, not a picture.
            //
            // The capture is explicit and narrow on purpose: this closure lives as long as the
            // player does, and an implicit `self` capture would pin the whole graph to it.
            fetchArtwork: { [factory = services.imagePipelineFactory, session] item in
                guard let ref = item.accentImageRef else { return nil }
                return await factory.imageData(for: ref, session: session,
                                               maxWidth: ArtworkAccent.thumbnailMaxPixel)
            }
        )
    }

    /// Read at asset construction for the ENGINE-facing knobs only (VLC's libass directory,
    /// freetype family, and the `--freetype-*` look an embedded SRT renders with). A closure,
    /// not a value: `SubtitlePreferences` loads its persisted style asynchronously, so a value
    /// read when the player was built could still be the pre-load default.
    private var subtitleStyleProvider: @MainActor () -> SubtitleStyle {
        { [subtitlePreferences] in subtitlePreferences.style }
    }

    /// URLSession does not throw on HTTP 4xx/5xx — it returns the error body. Without the status
    /// guard a server-side conversion failure hands back HTML/JSON "subtitles" and the ass→VTT
    /// fallback never fires.
    private nonisolated static func fetchSubtitle(
        _ url: URL, over session: URLSession, timeout: Duration
    ) async -> SubtitleFetchOutcome {
        let started = ContinuousClock().now
        // `…/Subtitles/{index}/…` on Jellyfin; the URL itself carries the token, so it stays out.
        let track = url.pathComponents.drop { $0 != "Subtitles" }.dropFirst().first ?? "?"
        let data: Data
        let response: URLResponse
        do {
            let request = URLRequest(url: url, timeoutInterval: timeout / .seconds(1))
            (data, response) = try await session.data(for: request)
        } catch {
            let code = (error as? URLError)?.code
            guard code != .cancelled else { return .rejected }
            let elapsed = started.duration(to: ContinuousClock().now)
            Log.playback.error("subtitle fetch failed: track=\(track, privacy: .public) URLError=\(code?.rawValue ?? 0) after \(elapsed, privacy: .public)")
            return code == .timedOut ? .notReady : .rejected
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard !data.isEmpty, status.map({ (200..<300).contains($0) }) ?? true else {
            let elapsed = started.duration(to: ContinuousClock().now)
            Log.playback.error("subtitle fetch failed: track=\(track, privacy: .public) status=\(status ?? 0) bytes=\(data.count) after \(elapsed, privacy: .public)")
            return .rejected
        }
        return .data(data)
    }
}

extension PlaybackPresenter.Request.Target {
    /// Whether the source this player was opened from is still configured as it was: the same
    /// Jellyfin session (same server, same token, since the player's repos carry it) or the same
    /// SMB server.
    func isLive(sessions: [Session], servers: [PersistedServer]) -> Bool {
        switch self {
        case .detail(_, let session, _), .itemID(_, let session, _):
            sessions.contains { $0.id == session.id && $0.accessToken == session.accessToken }
        case .smb(_, let ref):
            servers.contains { $0.id == ref.id }
        }
    }
}

extension ItemDetail {
    /// The artwork the scrub bar's accent is derived from. The poster for a movie; for an
    /// episode the still first, falling back through season to series art — the same
    /// `stillFirstImageRef` ladder the shelves and detail pages already show, so the bar's hue
    /// matches the picture the user pressed Play on. Series/season never play.
    nonisolated var accentImageRef: ImageRef? {
        switch self {
        case .movie(let detail): detail.movie.imageRef(.primary)
        case .episode(let detail): detail.episode.stillFirstImageRef
        case .series, .season: nil
        }
    }
}
