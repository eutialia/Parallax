import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// The add-SMB-server flow behind `SMBLoginView` and `SMBShareSelectionView`: collect host +
/// credentials, validate them by enumerating shares, let the user pick which shares to mount, and
/// save the server.
@Observable
@MainActor
public final class SMBAddServerModel {
    public var host = ""
    public var username = ""
    public var password = ""
    /// Defaulted, not user-editable — the form drops the Domain field (4 fields per the handoff);
    /// WORKGROUP covers the overwhelming common case and the connection still passes it through.
    public var domain = "WORKGROUP"

    public private(set) var connectionError: String?
    /// The single source of the connecting state — every exit path (success, error, timeout,
    /// cancel) resets this ONE value.
    public private(set) var isConnecting = false
    /// What the validated connection listed, for the share picker.
    public private(set) var discoveredShares: [SMBShare] = []
    /// Drives the pushed share picker.
    public var showShareSelector = false

    public private(set) var selectedShares: Set<String> = []
    public private(set) var isSaving = false
    public private(set) var saveError: String?

    /// Host is required; the account is optional (blank = guest, per the handoff footer).
    public var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
    }

    private let makeLister: @Sendable (SMBCredentials) -> any SMBLister
    private let serverStore: ServerStore
    private let discovery: SMBBonjourDiscovery
    private let lifecycle: AppLifecycle
    private let clock: any Clock<Duration>
    private let onSaved: () async -> Void

    /// The in-flight connection test. Held so backing out or a fresh tap can CANCEL it — without a
    /// handle the connect was fire-and-forget and couldn't be stopped, so a slow/dead host wedged
    /// the spinner with no way out.
    private var connectTask: Task<Void, Never>?
    /// Failsafe over the whole connect attempt. The lister already hard-bounds every AMSMB2 call,
    /// yet a device run still spun forever — so the attempt is ALSO bounded here, above every layer
    /// this model awaits.
    private var watchdogTask: Task<Void, Never>?
    /// Diagnostic breadcrumb: the last stage the connect attempt reached, surfaced by the watchdog's
    /// DEBUG error message.
    @ObservationIgnored private var stage = "idle"

    init(
        makeLister: @escaping @Sendable (SMBCredentials) -> any SMBLister,
        serverStore: ServerStore,
        discovery: SMBBonjourDiscovery,
        lifecycle: AppLifecycle,
        clock: any Clock<Duration>,
        onSaved: @escaping () async -> Void
    ) {
        self.makeLister = makeLister
        self.serverStore = serverStore
        self.discovery = discovery
        self.lifecycle = lifecycle
        self.clock = clock
        self.onSaved = onSaved
    }

    // MARK: - Bonjour discovery

    /// The SMB hosts Bonjour sees, for the form's picker rows.
    public var discoveredServers: [SMBDiscoveredServer] { discovery.discovered }

    /// Browses while the form is up; ending the calling task stops the browse. A browse that ended
    /// while the scene was away (the browser failed) starts again on the next activation.
    public func discoverServers() async {
        var seen = lifecycle.activations
        discovery.start()
        defer { discovery.stop() }
        for await count in Observations({ self.lifecycle.activations }) where count != seen {
            seen = count
            discovery.start()
        }
    }

    public func connect() {
        let trimHost = host.trimmingCharacters(in: .whitespaces)
        let trimUser = username.trimmingCharacters(in: .whitespaces)

        connectionError = nil
        isConnecting = true
        stage = "queued"
        let lister = makeLister(SMBCredentials(
            host: trimHost, username: trimUser, password: password, domain: domain
        ))

        // Replace any prior in-flight attempt and HOLD the handle so Cancel / leaving the form can
        // stop it. Post-`await` writes are gated on `!Task.isCancelled` so a backed-out attempt
        // never resurrects the spinner or pushes the share selector over a dismissed form.
        connectTask?.cancel()
        connectTask = Task {
            do {
                stage = "listing-shares"
                let shares = try await lister.listShares()
                stage = "listed(\(shares.count))"
                guard !Task.isCancelled else { return }
                // A server can enumerate ZERO visible shares (everything hidden/admin —
                // `listShares` filters `$` shares). Pushing the picker then strands the tvOS
                // focus engine on a screen whose only control is the disabled Add button — no
                // focusable element, dead remote. Surface it as an inline error instead.
                guard !shares.isEmpty else {
                    connectionError = "\(trimHost) has no shares to add. Check the server's shared folders."
                    finishConnecting()
                    return
                }
                // Adopt the validated (trimmed) values so what we persist EXACTLY matches what
                // connected — a stray space would otherwise reconnect to a different host and fail.
                // Password + domain are left as typed: those are exactly what the connection used.
                host = trimHost
                username = trimUser
                discoveredShares = shares
                selectedShares = []
                saveError = nil
                showShareSelector = true
            } catch {
                stage = "threw"
                guard !Task.isCancelled else { return }
                // Never expose the password in the error message.
                connectionError = "Couldn't connect to \(trimHost). Check the host and credentials."
            }
            finishConnecting()
        }

        watchdogTask?.cancel()
        watchdogTask = Task { [clock] in
            try? await clock.sleep(for: .seconds(30))
            guard !Task.isCancelled, isConnecting else { return }
            connectTask?.cancel()
            connectTask = nil
            isConnecting = false
            #if DEBUG
            connectionError = "Timed out after 30 s (stage: \(stage))."
            #else
            connectionError = "Timed out. Check the host and try again."
            #endif
        }
    }

    /// Abort an in-flight connection test and reset the form so the user isn't stranded on the
    /// spinner. The underlying AMSMB2 connect runs a C poll loop that can't observe Swift
    /// cancellation, but the lister's hard timeout bounds it and dropping the result here frees the
    /// form immediately.
    public func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        isConnecting = false
    }

    public func toggleShare(_ name: String) {
        if selectedShares.contains(name) { selectedShares.remove(name) } else { selectedShares.insert(name) }
    }

    /// Saves the server with the chosen shares and re-routes: a first source saved while logged
    /// out moves the app onto SMB-only home. Returns whether it saved.
    public func save() async -> Bool {
        guard !selectedShares.isEmpty, !isSaving else { return false }
        isSaving = true
        saveError = nil
        do {
            try await serverStore.addSMBServer(
                SMBServerData(host: host, username: username, domain: domain, shares: selectedShares.sorted()),
                password: password
            )
        } catch {
            saveError = "Couldn't save the shares. Try again."
            isSaving = false
            return false
        }
        await onSaved()
        return true
    }

    private func finishConnecting() {
        isConnecting = false
        watchdogTask?.cancel()
    }
}
