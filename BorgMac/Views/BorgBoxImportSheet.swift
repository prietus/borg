import SwiftUI
import AppKit

/// Adopts an existing repo from a BorgBox daemon into the local
/// `RepositoryStore`. Two modes:
///
/// - **existingKey**: the user already has an SSH key authorized for this
///   repo's `authorized_keys`. They pick it and we save locally.
/// - **register**: the repo exists on disk but has no key authorized
///   (daemon reports `registered: false`). We generate a fresh ed25519
///   key, call `POST /repos/import` on the daemon, then save locally.
///
/// Neither mode runs `borg init` — the repo already exists on the server.
struct BorgBoxImportSheet: View {
    enum Mode {
        case existingKey
        case register
    }

    @EnvironmentObject var repoStore: RepositoryStore
    @Environment(\.dismiss) private var dismiss

    let server: BorgBoxServer
    let remoteName: String
    let remotePath: String
    /// Optional canonical SSH URL from the daemon (v0.3.0 `ssh_url` field).
    /// When present, used verbatim instead of building from server fields.
    let remoteSSHUrl: String?
    let mode: Mode

    @State private var localName: String
    @State private var sshKeyPath: String
    @State private var passphrase: String = ""
    @State private var error: String?
    @State private var busy = false

    init(
        server: BorgBoxServer,
        remoteName: String,
        remotePath: String,
        remoteSSHUrl: String? = nil,
        mode: Mode = .existingKey
    ) {
        self.server = server
        self.remoteName = remoteName
        self.remotePath = remotePath
        self.remoteSSHUrl = remoteSSHUrl
        self.mode = mode
        _localName = State(initialValue: remoteName)
        // Auto-detect the BorgMac convention path: when this Mac was the one
        // that originally created the repo via the quick setup wizard,
        // SSHKeyGen names the file `~/.ssh/borgmac_borgbox_<remoteName>`
        // (the `borgmac_` prefix is added by SSHKeyGen, the wizard passes
        // `borgbox_<name>` as the slug).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("borgmac_borgbox_\(remoteName)").path
        let exists = FileManager.default.fileExists(atPath: candidate)
        _sshKeyPath = State(initialValue: exists ? candidate : "")
    }

    private var borgURL: String {
        if let remoteSSHUrl, !remoteSSHUrl.isEmpty {
            return remoteSSHUrl
        }
        return "ssh://\(server.sshUser)@\(server.sshHost):\(server.sshPort)\(remotePath)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Form {
                Section("Local") {
                    TextField("Name in BorgMac", text: $localName)
                    HStack(alignment: .firstTextBaseline) {
                        Text("SSH URL")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(borgURL)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if mode == .existingKey {
                    Section {
                        HStack {
                            TextField("Path to the private key", text: $sshKeyPath)
                                .font(.caption.monospaced())
                                .autocorrectionDisabled()
                            Button("Choose…") { pickKey() }
                        }
                        Text(sshKeyHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("SSH key")
                    }
                } else {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("A dedicated ed25519 key will be generated")
                                    .font(.body.weight(.medium))
                                Text("It will be stored at ~/.ssh/borgmac_borgbox_\(remoteName) and registered in the daemon's authorized_keys. This Mac will be able to use the repo without relying on any other keys.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } header: {
                        Text("SSH key")
                    }
                }

                Section("Passphrase") {
                    SecureField("Borg repository passphrase", text: $passphrase)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .register ? "Register and import" : "Import") {
                    performImport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(busy || !canImport)
            }
        }
        .padding(20)
        .frame(width: 580, height: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import repo from BorgBox").font(.title3.bold())
                Text("\(remoteName) — \(server.name)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sshKeyHelpText: String {
        if sshKeyPath.isEmpty {
            return "You need the SSH key that's already authorized on this repo. If this Mac is the one that created it via the wizard, it's usually at ~/.ssh/borgmac_borgbox_\(remoteName)."
        }
        return "Auto-detected from the BorgMac wizard convention. Change it if your key lives somewhere else."
    }

    private var canImport: Bool {
        guard !localName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !passphrase.isEmpty else { return false }
        if mode == .existingKey {
            return !sshKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: - Actions

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.prompt = "Use"
        // Allow picking dot-files like ssh keys.
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyPath = url.path
        }
    }

    private func performImport() {
        error = nil
        switch mode {
        case .existingKey:
            importWithExistingKey()
        case .register:
            Task { await registerAndImport() }
        }
    }

    private func importWithExistingKey() {
        busy = true
        defer { busy = false }

        let trimmedKey = sshKeyPath.trimmingCharacters(in: .whitespaces)
        guard FileManager.default.fileExists(atPath: trimmedKey) else {
            error = "The SSH key \(trimmedKey) does not exist."
            return
        }

        saveLocally(privateKeyPath: trimmedKey)
    }

    private func registerAndImport() async {
        busy = true
        defer { busy = false }

        let cleanName = remoteName
        do {
            let (privatePath, publicKey) = try SSHKeyGen.generate(
                slug: "borgbox_\(cleanName)",
                comment: "borgmac-borgbox-\(cleanName)"
            )
            _ = try await BorgBoxClient.shared.importRepo(
                server: server,
                name: cleanName,
                pubkey: publicKey
            )
            saveLocally(privateKeyPath: privatePath)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveLocally(privateKeyPath: String) {
        let repo = Repository(
            name: localName.trimmingCharacters(in: .whitespaces),
            url: borgURL,
            sshKeyPath: privateKeyPath
        )
        do {
            try repoStore.add(repo, passphrase: passphrase)
            try? Keychain.setBorgBoxRepoPassphrase(
                passphrase,
                serverId: server.id,
                repo: remoteName
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
