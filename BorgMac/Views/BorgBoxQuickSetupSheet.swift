import SwiftUI

struct BorgBoxQuickSetupSheet: View {
    @EnvironmentObject var repoStore: RepositoryStore
    @EnvironmentObject var serverStore: BorgBoxServerStore
    @Environment(\.dismiss) private var dismiss

    // Server form
    @State private var serverName: String = "My BorgBox server"
    @State private var daemonURL: String = "http://hive.local:9999"
    @State private var token: String = ""
    @State private var sshUser: String = "borg"
    @State private var sshPort: String = "22"
    @State private var sshHostOverride: String = ""
    @State private var showAdvanced: Bool = false

    // Repo form
    @State private var repoName: String = ""
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""

    // Existing repos on the daemon, fetched after server validation.
    @State private var remoteRepos: [BorgBoxRemoteRepo] = []
    @State private var loadingRemoteRepos = false
    @State private var importTarget: BorgBoxRemoteRepo?

    @State private var step: Step = .idle
    @State private var error: String?

    enum Step: Equatable {
        case idle
        case validatingServer
        case generatingKey
        case registeringRepo
        case initRepo
        case savingLocally
        case done

        var label: String {
            switch self {
            case .idle:              return ""
            case .validatingServer:  return "Validating server…"
            case .generatingKey:     return "Generating a dedicated SSH key…"
            case .registeringRepo:   return "Registering repo on the server (POST /repos)…"
            case .initRepo:          return "Initializing the Borg repository (borg init)…"
            case .savingLocally:     return "Saving to BorgMac…"
            case .done:              return "Done."
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .done: return false
            default: return true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if serverStore.first == nil {
                serverForm
            } else {
                repoForm
                    .task(id: serverStore.first?.id) { await loadRemoteRepos() }
            }
            if step != .idle {
                Divider()
                progressView
            }
            Spacer()
            footer
        }
        .padding(20)
        .frame(width: 620, height: 720)
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
        .sheet(item: $importTarget) { remote in
            if let server = serverStore.first {
                BorgBoxImportSheet(
                    server: server,
                    remoteName: remote.name,
                    remotePath: remote.path
                )
                .environmentObject(repoStore)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("New repository on BorgBox")
                    .font(.title3.bold())
                Text(serverStore.first == nil
                     ? "First, configure your BorgBox server."
                     : "Generate an SSH key, register with the daemon, and run borg init in one step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Server form

    private var serverForm: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $serverName, prompt: Text("e.g. Home NAS"))
                TextField("Daemon URL", text: $daemonURL,
                          prompt: Text("http://host:9999"))
                    .autocorrectionDisabled()
                SecureField("API token (Bearer)", text: $token)
            }

            Section {
                DisclosureGroup("SSH (advanced)", isExpanded: $showAdvanced) {
                    TextField("SSH host (empty = auto from URL)", text: $sshHostOverride,
                              prompt: Text(autoSshHost()))
                        .autocorrectionDisabled()
                    TextField("SSH user", text: $sshUser)
                    TextField("SSH port", text: $sshPort)
                }
            }

            Section {
                Text("The token is stored in the Keychain. The app checks `/health` and `/info` before saving to confirm the server is reachable and the token is valid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Repo form

    private var repoForm: some View {
        Form {
            Section("Server") {
                if let server = serverStore.first {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(server.name).font(.headline)
                            Text("\(server.daemonURL) — ssh: \(server.sshUser)@\(server.sshHost):\(server.sshPort)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
            }

            Section("Existing repos on the server") {
                if loadingRemoteRepos {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if remoteRepos.isEmpty {
                    Text("None yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteRepos) { remote in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(remote.name).font(.body.weight(.medium))
                                if let size = remote.sizeBytes {
                                    Text(formatBytes(size))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if isAlreadyImported(remote) {
                                Text("Already imported")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Import") {
                                    importTarget = remote
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Create a new repo") {
                TextField("Name",
                          text: $repoName,
                          prompt: Text("e.g. mac (lowercase, digits, hyphens)"))
                    .autocorrectionDisabled()
                SecureField("Passphrase", text: $passphrase)
                SecureField("Repeat passphrase", text: $passphraseConfirm)
            }

            Section {
                Text("The daemon validates the name: lowercase, digits and hyphens, 63 characters max.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func isAlreadyImported(_ remote: BorgBoxRemoteRepo) -> Bool {
        guard let server = serverStore.first else { return false }
        return repoStore.repositories.contains { local in
            local.url.contains(server.sshHost) && local.url.hasSuffix(remote.path)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }

    private func loadRemoteRepos() async {
        guard let server = serverStore.first else { return }
        loadingRemoteRepos = true
        defer { loadingRemoteRepos = false }
        do {
            remoteRepos = try await BorgBoxClient.shared.listRepos(server: server)
        } catch {
            // Non-fatal: the user can still create a new repo even if the
            // listing failed. We swallow silently so a daemon hiccup doesn't
            // ruin the wizard flow.
            remoteRepos = []
        }
    }

    // MARK: - Progress / footer

    private var progressView: some View {
        HStack(spacing: 10) {
            if step.isRunning {
                ProgressView().controlSize(.small)
            } else if case .done = step {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(step.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if serverStore.first != nil {
                Button("Forget server") {
                    if let s = serverStore.first {
                        serverStore.remove(s)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(step.isRunning)
                .help("Remove the server and its token from this Mac.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(step.isRunning)
            if serverStore.first == nil {
                Button("Save and connect") {
                    Task { await addServer() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddServer)
            } else {
                Button("Create repo") {
                    Task { await runRepoWizard() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreateRepo)
            }
        }
    }

    private var canAddServer: Bool {
        guard case .idle = step else { return false }
        if serverName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if daemonURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if token.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private var canCreateRepo: Bool {
        guard case .idle = step else { return false }
        let name = repoName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        guard passphrase.count >= 1 && passphrase == passphraseConfirm else { return false }
        return true
    }

    // MARK: - Actions

    private func autoSshHost() -> String {
        guard let comps = URLComponents(string: daemonURL), let host = comps.host else {
            return ""
        }
        return host
    }

    private func addServer() async {
        let cleanURL = daemonURL.trimmingCharacters(in: .whitespaces)
        let cleanToken = token.trimmingCharacters(in: .whitespaces)
        let cleanName = serverName.trimmingCharacters(in: .whitespaces)

        let host = sshHostOverride.trimmingCharacters(in: .whitespaces).isEmpty
            ? autoSshHost()
            : sshHostOverride.trimmingCharacters(in: .whitespaces)
        let port = Int(sshPort.trimmingCharacters(in: .whitespaces)) ?? 22
        let user = sshUser.trimmingCharacters(in: .whitespaces).isEmpty
            ? "borg"
            : sshUser.trimmingCharacters(in: .whitespaces)

        guard !host.isEmpty else {
            self.error = "Could not extract a host from the daemon URL. Set one under SSH (advanced)."
            return
        }

        step = .validatingServer
        defer { if case .validatingServer = step { step = .idle } }
        do {
            try await BorgBoxClient.shared.health(daemonURL: cleanURL)
            _ = try await BorgBoxClient.shared.info(daemonURL: cleanURL, token: cleanToken)
        } catch {
            self.error = error.localizedDescription
            step = .idle
            return
        }

        let server = BorgBoxServer(
            name: cleanName,
            daemonURL: cleanURL,
            sshHost: host,
            sshUser: user,
            sshPort: port
        )
        do {
            try serverStore.add(server, token: cleanToken)
            step = .idle
        } catch {
            self.error = error.localizedDescription
            step = .idle
        }
    }

    private func runRepoWizard() async {
        guard let server = serverStore.first else { return }
        let cleanName = repoName.trimmingCharacters(in: .whitespaces)

        do {
            // 1. Generate fresh ed25519 key dedicated to this repo.
            step = .generatingKey
            let (privateKeyPath, publicKey) = try SSHKeyGen.generate(
                slug: "borgbox_\(cleanName)",
                comment: "borgmac-borgbox-\(cleanName)"
            )

            // 2. Register the repo on the daemon (POST /repos with name + pubkey).
            step = .registeringRepo
            let created = try await BorgBoxClient.shared.createRepo(
                server: server,
                name: cleanName,
                pubkey: publicKey
            )

            // 3. Compose the SSH URL for borg init using the daemon's absolute
            //    path combined with our configured ssh user/host/port.
            let borgURL = "ssh://\(server.sshUser)@\(server.sshHost):\(server.sshPort)\(created.path)"

            // 4. borg init over SSH with the dedicated key.
            step = .initRepo
            try await BorgClient.shared.initRepo(
                url: borgURL,
                passphrase: passphrase,
                sshKeyPath: privateKeyPath
            )

            // 5. Save locally with sshKeyPath wired so every borg call uses it.
            step = .savingLocally
            let repo = Repository(
                name: created.name,
                url: borgURL,
                sshKeyPath: privateKeyPath
            )
            try repoStore.add(repo, passphrase: passphrase)

            step = .done
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            step = .idle
        }
    }
}
