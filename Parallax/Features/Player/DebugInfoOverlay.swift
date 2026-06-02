#if DEBUG
import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

/// A debug-only heads-up display over the player, surfacing what's *actually*
/// playing on device: the server's routing decision + per-stream metadata, and
/// the engine's live decode/track truth. Built to diagnose subtitle problems —
/// "out of sync" and "selected but doesn't render" — so the subtitle section
/// cross-checks the menu selection against the engine's active track and flags
/// the segmented-WebVTT desync path.
///
/// DEBUG-only: the whole file compiles out of release builds.
struct DebugInfoOverlay: View {
    let vm: PlayerViewModel
    let onClose: () -> Void

    @State private var snapshot: PlaybackDebugInfo = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header
                deliverySection
                videoSection
                audioSection
                subtitleSection
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .frame(maxWidth: 380, maxHeight: 460, alignment: .topLeading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .task {
            // Poll the engine's live snapshot; cancelled when the HUD disappears.
            while !Task.isCancelled {
                snapshot = await vm.currentDebugSnapshot()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
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

    @ViewBuilder
    private var deliverySection: some View {
        sectionHeader("DELIVERY")
        if let r = vm.debugResolved {
            row("method", String(describing: r.method))
            row("container", r.container.map { String(describing: $0) } ?? "—")
            if !r.transcodeReasons.isEmpty {
                row("reason", r.transcodeReasons.joined(separator: ", "))
            }
            if let req = requestedIndices { row("requested", req) }
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
        if let delay = snapshot.subtitleDelayMs {
            subtitleDelayControl(current: delay)
        }
    }

    /// VLC-only live retiming: proves whether the SRT/ASS is correctly timed
    /// (a working ± nudge that fixes sync points at the segmented-WebVTT path).
    private func subtitleDelayControl(current: Int) -> some View {
        HStack(spacing: 10) {
            Text("delay")
            Button("−100ms") { Task { await vm.setSubtitleDelay(ms: current - 100) } }
                .buttonStyle(.bordered)
            Text("\(current) ms").bold().frame(minWidth: 56)
            Button("+100ms") { Task { await vm.setSubtitleDelay(ms: current + 100) } }
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
                .textSelection(.enabled)
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
#endif
