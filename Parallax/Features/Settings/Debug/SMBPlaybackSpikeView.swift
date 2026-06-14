#if DEBUG
import SwiftUI
import VLCKitSPM
import ParallaxPlayback

/// Throwaway Phase-2 spike: does MobileVLCKit play smb:// against the real NAS?
/// Decides the streaming architecture. DELETE at the end of Phase 2 (Task 12).
///
/// Credentials are passed via VLC media options ONLY — they never appear in the
/// URL string or in any log output.
struct SMBPlaybackSpikeView: View {
    @State private var host = ""
    @State private var share = ""
    @State private var path = ""          // e.g. "Movies/example.mkv"
    @State private var user = ""
    @State private var password = ""
    @State private var domain = "WORKGROUP"
    @State private var status = "idle"
    @State private var player: VLCMediaPlayer?

    var body: some View {
        Form {
            Section("Target") {
                TextField("Host (e.g. 192.168.1.10)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Share", text: $share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Path within share", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Credentials") {
                TextField("Username", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                TextField("Domain", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Result") {
                Text(status).monospaced()
            }
            Section {
                Button("Play", action: play)
                Button("Stop", action: stop)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("SMB Spike")
    }

    // MARK: - Actions

    private func play() {
        stop()
        // Credentials go through media options, NEVER the URL string.
        guard let url = URL(string: "smb://\(host)/\(share)/\(path)") else {
            status = "error: bad url"
            return
        }
        guard let media = VLCMedia(url: url) else {
            status = "error: VLCMedia rejected url"
            return
        }
        media.addOption(":smb-user=\(user)")
        media.addOption(":smb-pwd=\(password)")
        media.addOption(":smb-domain=\(domain)")
        // Route VLC events to the main queue before the player exists — otherwise,
        // if the spike is the first VLC consumer this launch, state callbacks may
        // never reach the delegate and the status readout stays dead.
        VLCKitEngine.configureVLCEvents()
        let p = VLCMediaPlayer()
        p.media = media
        SpikeDelegate.shared.onState = { [weak p] state in
            let timeMs = p?.time.intValue ?? -1
            status = "state=\(state) time=\(timeMs)ms"
        }
        p.delegate = SpikeDelegate.shared
        p.play()
        player = p
        status = "play requested…"
    }

    private func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        SpikeDelegate.shared.onState = nil
    }
}

// MARK: - Delegate

private final class SpikeDelegate: NSObject, VLCMediaPlayerDelegate {
    static let shared = SpikeDelegate()
    var onState: ((String) -> Void)?

    /// VLCKit 4.x delivers state directly as `VLCMediaPlayerState`, not a Notification.
    /// `VLCMediaPlayerStateToString` returns a non-optional NSString.
    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        let label = VLCMediaPlayerStateToString(newState) as String
        DispatchQueue.main.async { [weak self] in
            self?.onState?(label)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SMBPlaybackSpikeView()
    }
}
#endif
