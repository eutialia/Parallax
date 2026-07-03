#if DEBUG
import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

/// A debug-only panel surfacing what's *actually* playing on device: the
/// server's routing decision + per-stream metadata, and the engine's live
/// decode/track/transport truth. Built to diagnose subtitle problems and
/// silent stalls ("never plays, no error" — see the transport/rx/error rows).
///
/// Presented through the chip row's `trackPresentation` like the track menus
/// (sheet on tvOS / popover on iPad): on tvOS a ScrollView only scrolls by
/// moving FOCUS, so each section is a focus stop the remote steps through.
///
/// DEBUG-only: the whole file compiles out of release builds.
struct DebugInfoOverlay: View {
    let vm: PlayerViewModel
    let onClose: () -> Void

    /// Single instance (final-review M3) — a picker write and a label read must hit the
    /// same `UserDefaults`-backed seam, and three inline `StartupTuningStore()` values
    /// were harmless (all wrap `.standard`) but pointless.
    private let startupTuningStore = StartupTuningStore()

    @State private var snapshot: PlaybackDebugInfo = .empty
    /// Mirrors `snapshot`'s polling pattern (final-review M1): the label below read the
    /// store inline, which only reflected a pick once *something else* re-rendered the
    /// view — polled here instead so the profile row is honest on its own.
    @State private var startupProfile: StartupProfile = .system

    /// Readable at couch distance on the tvOS canvas; dense on touch screens.
    private var fontSize: CGFloat {
        #if os(tvOS)
        24
        #else
        11
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                focusStop { header }
                focusStop { startupSection }
                focusStop { deliverySection }
                focusStop { videoSection }
                focusStop { audioSection }
                focusStop { subtitleSection }
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task {
            // Poll the engine's live snapshot; cancelled when the HUD disappears. The
            // profile rides the same loop (final-review M1) so a pick from the menu below
            // shows up within one tick instead of waiting on an unrelated re-render.
            while !Task.isCancelled {
                snapshot = await vm.currentDebugSnapshot()
                startupProfile = startupTuningStore.selected
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    /// tvOS: a section is a focus stop, so D-pad up/down walks the panel and the
    /// ScrollView follows focus (its only scrolling mechanism there). The subtle
    /// dim lift marks where focus sits. Elsewhere the wrapper is inert.
    @ViewBuilder
    private func focusStop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        FocusableSection { content() }
        #else
        content()
        #endif
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("DEBUG · \(engineLabel)").bold()
            Spacer()
            Button("Hide debug overlay", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .foregroundStyle(.white)
        }
        .padding(.bottom, 4)
    }

    /// Plan C (AVKit startup tuning): the play()→first-`.playing` wall-clock metric next
    /// to a picker for the DEBUG-selected buffering profile driving it. AVKit-only —
    /// `engineLabel` still reports the true engine in the header.
    @ViewBuilder
    private var startupSection: some View {
        sectionHeader("STARTUP")
        row("time", startupMetricLabel)
        startupProfilePicker
    }

    private var startupMetricLabel: String {
        let ms = vm.startupMillis.map { "\($0) ms" } ?? "—"
        return "\(ms) (\(startupProfile.displayName))"
    }

    /// Writing the store has no live effect on the running session — `AppDependencies`'
    /// engine factory reads it only at engine-construction time, so a pick here takes
    /// effect on the NEXT playback session, not this one (caption says so). The label
    /// updates immediately (not waiting on the next poll tick) since the pick happens
    /// right here.
    private var startupProfilePicker: some View {
        HStack(spacing: 8) {
            Text("profile")
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 78, alignment: .leading)
            Menu {
                ForEach(StartupProfile.allCases, id: \.self) { profile in
                    Button(profile.displayName) {
                        startupTuningStore.selected = profile
                        startupProfile = profile
                    }
                }
            } label: {
                Text(startupProfile.displayName)
            }
            .tint(.white)
            Text("· applies next session")
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var deliverySection: some View {
        sectionHeader("DELIVERY")
        if let r = vm.debugResolved {
            row("method", String(describing: r.method))
            row("delivery", deliveryLine)
            row("container", r.container.map { String(describing: $0) } ?? "—")
            if !r.transcodeReasons.isEmpty {
                row("reason", r.transcodeReasons.joined(separator: ", "))
            }
            if let req = requestedIndices { row("requested", req) }
        } else if vm.phase == .playing {
            // No Jellyfin resolve object, but the engine is playing: this is the SMB/local
            // path, which plays straight off the file URL with no server routing decision —
            // so "resolving…" would be misleading. (`resolved` is nil by design there.)
            row("method", "local/SMB direct")
        } else {
            row("state", "resolving…")
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        sectionHeader("VIDEO")
        if let v = streams(.video).first {
            row("codec", [v.codec, v.profile].compactMap { $0 }.joined(separator: " "))
            row("range", [v.videoRange, v.videoRangeType].compactMap { $0 }.joined(separator: " / "))
            row("source", dimensions(v.width, v.height, fps: v.frameRate, bitDepth: v.bitDepth))
            if let cs = v.colorSpace { row("colorspace", cs) }
            if let br = v.bitRate { row("bitrate", bitrate(Double(br))) }
        } else {
            row("source", "—")
        }
        // What the engine is decoding right now (differs from source on a transcode).
        row("decoding", decodingNow)
        if snapshot.indicatedBitrate != nil || snapshot.observedBitrate != nil {
            row("net", netBitrates)
        }
        if let dropped = snapshot.droppedVideoFrames { row("dropped", "\(dropped) frames") }
        if let buf = snapshot.bufferedSeconds { row("buffered", String(format: "%.1fs", buf)) }
        // Stall forensics: where the playhead actually is vs where the data
        // actually sits (a range parked away from the playhead = the resume
        // gap wedge), the raw transport state (incl. WHY AVPlayer is waiting),
        // data actually pulled, and the silent HLS error-log tail — the triage
        // kit for "never plays, no error".
        if let head = snapshot.playheadSeconds { row("playhead", String(format: "%.1fs", head)) }
        if !snapshot.loadedRanges.isEmpty {
            row("ranges", snapshot.loadedRanges.joined(separator: "  "))
        }
        if let status = snapshot.itemStatus { row("item", status) }
        if let transport = snapshot.transportState { row("transport", transport) }
        if let stalls = snapshot.stallCount, stalls > 0 { row("stalls", "\(stalls)") }
        if let rx = snapshot.bytesTransferred {
            row("rx", ByteCountFormatter.string(fromByteCount: rx, countStyle: .binary))
        }
        ForEach(Array(snapshot.errorLogTail.enumerated()), id: \.offset) { _, line in
            Text(line)
                .foregroundStyle(.yellow)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        sectionHeader("AUDIO")
        let audio = streams(.audio)
        if audio.isEmpty {
            row("streams", "—")
        } else {
            ForEach(audio) { s in
                row(marker(s), audioDescription(s))
            }
        }
        row("engine ▸", snapshot.selectedAudible ?? "—")
    }

    @ViewBuilder
    private var subtitleSection: some View {
        sectionHeader("SUBTITLES")
        let subs = streams(.subtitle)
        if subs.isEmpty {
            row("streams", "—")
        } else {
            ForEach(subs) { s in
                row(marker(s), subtitleDescription(s))
            }
        }
        // Engine truth — the live diagnosis for "selected but doesn't render".
        row("engine ▸", snapshot.selectedLegible ?? "none active")
        // Client-side path: on a transcode we fetch a correctly-timed sidecar
        // VTT and draw it ourselves (SubtitleOverlayView), so `engine ▸` reading
        // "none active" is EXPECTED — the cues render via the overlay, not AVPlayer.
        if !vm.activeSubtitleCues.isEmpty {
            row("client ▸", "\(vm.activeSubtitleCues.count) cues · sidecar VTT")
        }
        if let warning = subtitleWarning {
            Text(warning)
                .foregroundStyle(.yellow)
                .padding(.top, 2)
        }
        // Retime control: client-drawn sidecar cues nudge in the overlay
        // (`clientSubtitleDelayMs` — the transcode seek-desync escape hatch); an
        // engine-rendered embedded track nudges in the engine (VLC). Gate on the SAME
        // intent predicate `setSubtitleDelay` routes by, so the control can't show one
        // renderer's value while the nudge lands on the other's.
        if vm.usesClientSubtitleRendering {
            subtitleDelayControl(current: vm.clientSubtitleDelayMs)
        } else if let delay = snapshot.subtitleDelayMs {
            subtitleDelayControl(current: delay)
        }
    }

    /// Live subtitle retiming nudge. Coarse (±1s) for the multi-second Jellyfin
    /// transcode seek desync on the client overlay; fine (±100ms) for ordinary sync
    /// points. A working nudge also proves the offset is a clean constant.
    private func subtitleDelayControl(current: Int) -> some View {
        HStack(spacing: 8) {
            Text("delay")
            Button("−1s") { Task { await vm.setSubtitleDelay(ms: current - 1000) } }
                .buttonStyle(.bordered)
            Button("−100") { Task { await vm.setSubtitleDelay(ms: current - 100) } }
                .buttonStyle(.bordered)
            Text("\(current) ms").bold().frame(minWidth: 64)
            Button("+100") { Task { await vm.setSubtitleDelay(ms: current + 100) } }
                .buttonStyle(.bordered)
            Button("+1s") { Task { await vm.setSubtitleDelay(ms: current + 1000) } }
                .buttonStyle(.bordered)
        }
        .controlSize(.mini)
        .tint(.white)
        .padding(.top, 2)
    }

    // MARK: - Row / header builders

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 6)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
    }

    // MARK: - Derived values

    private var engineLabel: String {
        switch vm.debugEngineID {
        case .avKit: "AVKit"
        case .vlcKit: "VLCKit"
        case nil: "—"
        }
    }

    /// The live copy-vs-reencode verdict from the running session's `TranscodingInfo`
    /// (`vm.transcodeDelivery`), folded with the routing method. Direct play needs no
    /// probe; a transcode reads "probing…" until the ~2s-delayed fetch lands, then
    /// "Remux (video copy, …)" for a stream-copy or "Transcode (<reasons>)" for a
    /// re-encode — the signal the seek strategy gates on.
    private var deliveryLine: String {
        guard let method = vm.debugResolved?.method else { return "—" }
        switch method {
        case .directPlay:
            return "Direct Play"
        case .transcode:
            guard let d = vm.transcodeDelivery else {
                return vm.deliveryProbeExhausted ? "Transcode (no delivery info)" : "Transcode (probing…)"
            }
            if d.isVideoDirect {
                return "Remux (video copy, \(d.audioCodec ?? "audio copy"))"
            }
            let reasons = d.transcodeReasons.isEmpty ? "re-encode" : d.transcodeReasons.joined(separator: ", ")
            return "Transcode (→\(d.videoCodec ?? "?"): \(reasons))"
        }
    }

    private func streams(_ kind: MediaStreamInfo.Kind) -> [MediaStreamInfo] {
        (vm.debugResolved?.mediaStreams ?? []).filter { $0.kind == kind }
    }

    /// `▸` marks the stream index the menu has selected (transcode path), else a space.
    private func marker(_ s: MediaStreamInfo) -> String {
        let selected = vm.selectedAudioTrack?.id.jellyfinStreamIndex == s.index
            || vm.selectedSubtitleTrack?.id.jellyfinStreamIndex == s.index
        return selected ? "▸ \(s.index)" : "  \(s.index)"
    }

    private func audioDescription(_ s: MediaStreamInfo) -> String {
        var parts = [s.displayTitle ?? s.language ?? "Track \(s.index)"]
        if let codec = s.codec { parts.append(codec) }
        if let ch = s.channels { parts.append("\(ch)ch") }
        if let sr = s.sampleRate { parts.append("\(sr / 1000)kHz") }
        if let br = s.bitRate { parts.append(bitrate(Double(br))) }
        return parts.joined(separator: " · ")
    }

    private func subtitleDescription(_ s: MediaStreamInfo) -> String {
        var parts = [s.displayTitle ?? s.language ?? "Track \(s.index)"]
        if let codec = s.codec { parts.append(codec) }
        if let delivery = s.subtitleDeliveryMethod { parts.append(deliveryNote(delivery)) }
        if s.isExternal { parts.append("ext") }
        if s.isForced { parts.append("forced") }
        if s.isImageSubtitle { parts.append("image→burn-in") }
        return parts.joined(separator: " · ")
    }

    /// Annotates the delivery method with the sync implication.
    private func deliveryNote(_ method: String) -> String {
        switch method {
        case "Hls": "Hls⚠︎desync"
        case "Encode": "Encode(burn-in)"
        default: method
        }
    }

    /// A live diagnosis line for the two subtitle bugs.
    private var subtitleWarning: String? {
        // Client-side rendering active: cues are drawn by SubtitleOverlayView from
        // a correctly-timed sidecar VTT, so the engine-selection / HLS-desync
        // diagnostics below don't apply — suppress them to avoid false alarms.
        if !vm.activeSubtitleCues.isEmpty { return nil }

        let pickedInMenu = vm.selectedSubtitleTrack != nil
        let activeInEngine = snapshot.selectedLegible != nil
        if pickedInMenu && !activeInEngine && !snapshot.legibleOptions.isEmpty {
            return "⚠︎ picked in menu but no subtitle active in engine"
        }
        let hasHlsSub = streams(.subtitle).contains { $0.subtitleDeliveryMethod == "Hls" }
        if hasHlsSub {
            return "⚠︎ HLS/WebVTT delivery — known AVFoundation desync; VLC direct-play or burn-in syncs"
        }
        return nil
    }

    private var decodingNow: String {
        guard let w = snapshot.presentationWidth, let h = snapshot.presentationHeight else { return "—" }
        var s = "\(w)×\(h)"
        if let fps = snapshot.renderedFrameRate { s += String(format: " · %.3g fps", fps) }
        return s
    }

    private var netBitrates: String {
        let indicated = snapshot.indicatedBitrate.map { "indic \(bitrate($0))" }
        let observed = snapshot.observedBitrate.map { "obs \(bitrate($0))" }
        return [observed, indicated].compactMap { $0 }.joined(separator: " · ")
    }

    private var requestedIndices: String? {
        guard let url = vm.debugResolved?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let keys = ["AudioStreamIndex", "SubtitleStreamIndex", "SubtitleMethod"]
        let pairs = keys.compactMap { key in
            items.first { $0.name == key }?.value.map { "\(key)=\($0)" }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: " ")
    }

    private func dimensions(_ w: Int?, _ h: Int?, fps: Double?, bitDepth: Int?) -> String {
        var parts: [String] = []
        if let w, let h { parts.append("\(w)×\(h)") }
        if let fps { parts.append(String(format: "%.3g fps", fps)) }
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func bitrate(_ bps: Double) -> String {
        bps >= 1_000_000
            ? String(format: "%.1f Mbps", bps / 1_000_000)
            : String(format: "%.0f kbps", bps / 1_000)
    }
}

#if os(tvOS)
/// A focusable, non-interactive block: the debug panel's sections become focus
/// stops so the remote can scroll the ScrollView (tvOS scrolls only by moving
/// focus). The focused section lifts slightly so the user can see where the
/// D-pad is — `.focusable()` alone paints no indicator.
private struct FocusableSection<Content: View>: View {
    let content: Content
    @FocusState private var focused: Bool

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(6)
            .background(.white.opacity(focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .focusable()
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif
#endif
