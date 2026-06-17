import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Add-SMB-server form: collects host / share / credentials, validates the connection by
/// doing a real `list(share:path:"")`, then hands off to `SMBFolderPickerView` to let the
/// user choose which subfolder of the share is the library root.
///
/// Discovery lifecycle mirrors `LoginView`: `deps.smbDiscovery.start()` on appear,
/// `stop()` on disappear, `#if !os(tvOS)` gated because tvOS has no mDNS LAN discovery
/// prompt and the Bonjour browser is unconditional (no permission gate — safe to run on
/// tvOS too, but the picker rows are irrelevant on the 10-foot UI).
struct SMBLoginView: View {
    /// Called after a server is successfully saved (folder selected + stored in Keychain).
    var onAdded: () -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(\.scenePhase) private var scenePhase

    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = "WORKGROUP"

    @State private var isConnecting = false
    @State private var connectionError: String?

    /// The live lister handed to the picker AFTER a successful connection test.
    /// Holding it here (not as a navigation value) because `AMSMB2Lister` is an actor
    /// and can't be made `Hashable` for `.navigationDestination(for:)`. Instead we push
    /// by setting this and using a `navigationDestination(isPresented:)` binding.
    @State private var pendingLister: AMSMB2Lister?
    @State private var showFolderPicker = false

    #if !os(tvOS)
    @ScaledMetric(relativeTo: .headline) private var baseControlHeight: CGFloat = 50
    #endif

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
        && !share.trimmingCharacters(in: .whitespaces).isEmpty
        && !username.trimmingCharacters(in: .whitespaces).isEmpty
        && !isConnecting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s22) {
                #if !os(tvOS)
                discoveredServersSection
                #endif

                fieldsSection

                if let error = connectionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.s14)
                }

                connectButton
            }
            .padding(Space.s18)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        #if !os(tvOS)
        .onAppear { deps.smbDiscovery.start() }
        .onDisappear { deps.smbDiscovery.stop() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            deps.smbDiscovery.start()
        }
        #endif
        .navigationDestination(isPresented: $showFolderPicker) {
            if let lister = pendingLister {
                SMBFolderPickerView(
                    lister: lister,
                    host: host,
                    share: share,
                    username: username,
                    password: password,
                    domain: domain,
                    onAdded: onAdded
                )
            }
        }
    }

    // MARK: - Discovered servers

    #if !os(tvOS)
    @ViewBuilder
    private var discoveredServersSection: some View {
        if !deps.smbDiscovery.discovered.isEmpty {
            VStack(spacing: 0) {
                ForEach(deps.smbDiscovery.discovered) { server in
                    Button {
                        host = server.host
                    } label: {
                        HStack(spacing: Space.s12) {
                            Image(systemName: "network")
                                .foregroundStyle(Color.secondaryLabel)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.label)
                                Text(server.host)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryLabel)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Space.s8)
                        .padding(.horizontal, Space.s14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        }
    }
    #endif

    // MARK: - Fields

    /// tvOS uses the Settings-style row list (rows → single-field keyboard screen, no inline field
    /// pill); iOS keeps the inline grouped fields. See `CredentialRowList` for why.
    @ViewBuilder
    private var fieldsSection: some View {
        #if os(tvOS)
        CredentialRowList(rows: credentialRows)
        #else
        connectionFieldsSection
        #endif
    }

    #if os(tvOS)
    private var credentialRows: [CredentialRow] {
        [
            CredentialRow(id: "host", icon: "server.rack", title: "Host", placeholder: "e.g. 192.168.1.10", text: $host, keyboard: .URL),
            CredentialRow(id: "share", icon: "externaldrive.connected.to.line.below.fill", title: "Share name", placeholder: "Share name", text: $share),
            CredentialRow(id: "username", icon: "person", title: "Username", placeholder: "Username", text: $username),
            CredentialRow(id: "password", icon: "lock", title: "Password", placeholder: "Password", text: $password, isSecure: true),
            CredentialRow(id: "domain", icon: "building.2", title: "Domain", placeholder: "Domain", text: $domain, autocapitalization: .characters),
        ]
    }
    #endif

    #if !os(tvOS)
    private var connectionFieldsSection: some View {
        VStack(spacing: 0) {
            fieldRow(icon: "server.rack") {
                TextField("Host (e.g. 192.168.1.10)", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            hairline
            fieldRow(icon: "externaldrive.connected.to.line.below.fill") {
                TextField("Share name", text: $share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            hairline
            fieldRow(icon: "person") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            hairline
            fieldRow(icon: "lock") {
                SecureField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            hairline
            fieldRow(icon: "building.2") {
                TextField("Domain", text: $domain)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }
    #endif

    // MARK: - Connect button

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            Text("Connect").formActionLabel(.solid, isWorking: isConnecting)
        }
        .formActionButton(.solid)
        .disabled(!canConnect)
    }

    // MARK: - Connection logic

    private func connect() {
        let trimHost = host.trimmingCharacters(in: .whitespaces)
        let trimShare = share.trimmingCharacters(in: .whitespaces)
        let trimUser = username.trimmingCharacters(in: .whitespaces)

        connectionError = nil
        isConnecting = true

        // Capture to avoid closing over @State bindings inside the Task.
        let capturedPassword = password
        let capturedDomain = domain

        Task {
            let lister = AMSMB2Lister(
                host: trimHost,
                username: trimUser,
                password: capturedPassword,
                domain: capturedDomain
            )
            do {
                _ = try await lister.list(share: trimShare, path: "")
                // Adopt the validated (trimmed) values so what we persist EXACTLY matches
                // what connected. SMBFolderPickerView reads these straight into the saved
                // SMBServerData, and the media-repo factory later reconnects with them — if
                // we persisted the raw, untrimmed fields, a stray space would reconnect to a
                // different host/share and fail (browse works, the grid throws). Password +
                // domain are left as typed: those are exactly what the connection used.
                host = trimHost
                share = trimShare
                username = trimUser
                // Hand the connected lister to the folder picker.
                pendingLister = lister
                showFolderPicker = true
            } catch {
                // Disconnect so the actor doesn't hold a dangling connection.
                await lister.disconnect()
                // Never expose the password in the error message.
                connectionError = "Couldn't connect to \(trimHost)/\(trimShare). Check the host, share, and credentials."
            }
            isConnecting = false
        }
    }

    // MARK: - Layout helpers (iOS inline fields; tvOS uses CredentialRowList)

    #if !os(tvOS)
    private var hairline: some View {
        Rectangle().fill(Color.separator).frame(height: 1).padding(.leading, 44)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.s12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Color.tertiaryLabel)
            content()
        }
        .padding(.horizontal, Space.s14)
        .frame(height: baseControlHeight)
    }
    #endif
}
