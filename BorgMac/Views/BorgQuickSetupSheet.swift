import SwiftUI
import AppKit

struct BorgQuickSetupSheet: View {
    @EnvironmentObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case local = "Local folder"
        case ssh = "Remote SSH"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .local
    @State private var localPath: String = ""
    @State private var sshUrl: String = ""
    @State private var name: String = ""
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""
    @State private var encryption: Encryption = .repokeyBlake2
    @State private var step: Step = .idle
    @State private var error: String?
    @State private var availableKeys: [LocalSSHKey] = []
    @State private var selectedKeyPath: String? = nil  // nil = ssh-agent default

    enum Encryption: String, CaseIterable, Identifiable {
        case repokeyBlake2  = "repokey-blake2"
        case repokey        = "repokey"
        case keyfileBlake2  = "keyfile-blake2"
        case none           = "none"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .repokeyBlake2: return "Encrypted — key stored in repo (recommended)"
            case .repokey:       return "Encrypted — key in repo, HMAC-SHA256"
            case .keyfileBlake2: return "Encrypted — key on this Mac only (advanced)"
            case .none:          return "No encryption"
            }
        }

        var helpText: String? {
            switch self {
            case .repokeyBlake2, .repokey:
                return nil
            case .keyfileBlake2:
                return "The encryption key lives in ~/.config/borg/keys/ on this Mac. If you lose it the repo is unrecoverable — back it up separately."
            case .none:
                return "Anyone with access to the repo can read your data. Only choose this for throwaway test repos."
            }
        }
    }

    enum Step: Equatable {
        case idle
        case initializing
        case savingLocally
        case done

        var label: String {
            switch self {
            case .idle:         return ""
            case .initializing: return "Initializing the Borg repository (borg init)…"
            case .savingLocally: return "Saving to BorgMac…"
            case .done:         return "Done."
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .done: return false
            default: return true
            }
        }
    }

    private var location: String {
        switch mode {
        case .local: return localPath.trimmingCharacters(in: .whitespaces)
        case .ssh:   return sshUrl.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            form
            if step != .idle {
                Divider()
                progressView
            }
            Spacer()
            footer
        }
        .padding(20)
        .frame(width: 600, height: 620)
        .task {
            availableKeys = SSHKeyDiscovery.list()
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Borg repository").font(.title3.bold())
                Text("Initialize a Borg repository in a local folder or on your own SSH server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(step.isRunning)
            }

            Section("Location") {
                switch mode {
                case .local:
                    HStack {
                        TextField("/path/to/repository", text: $localPath)
                            .disabled(step.isRunning)
                            .autocorrectionDisabled()
                        Button("Choose…") { pickFolder() }
                            .disabled(step.isRunning)
                    }
                case .ssh:
                    TextField("ssh://user@host:port/./repo", text: $sshUrl)
                        .disabled(step.isRunning)
                        .autocorrectionDisabled()
                }
            }

            Section("Repository") {
                TextField("Name",
                          text: $name,
                          prompt: Text(suggestedName().isEmpty ? "e.g. personal-server" : suggestedName()))
                    .disabled(step.isRunning)
                SecureField("Passphrase", text: $passphrase)
                    .disabled(step.isRunning)
                SecureField("Repeat passphrase", text: $passphraseConfirm)
                    .disabled(step.isRunning)
            }

            Section("Encryption") {
                Picker("Mode", selection: $encryption) {
                    ForEach(Encryption.allCases) { Text($0.label).tag($0) }
                }
                .disabled(step.isRunning)
                if let help = encryption.helpText {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if mode == .ssh {
                Section("SSH key") {
                    Picker("Key to use", selection: $selectedKeyPath) {
                        Text("Default (ssh-agent / ~/.ssh/config)")
                            .tag(String?.none)
                        ForEach(availableKeys) { key in
                            Text(key.displayName)
                                .tag(String?.some(key.privatePath))
                        }
                    }
                    if let selectedKeyPath {
                        Text(selectedKeyPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("If your SSH key is passphrase-protected, make sure it is loaded in `ssh-agent` before running the wizard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

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
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(step.isRunning)
            Button("Create") { Task { await runWizard() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
    }

    private var canCreate: Bool {
        guard case .idle = step else { return false }
        guard !location.isEmpty else { return false }
        guard passphrase.count >= 1 && passphrase == passphraseConfirm else { return false }
        return true
    }

    // MARK: - Helpers

    private func suggestedName() -> String {
        let base: String
        switch mode {
        case .local:
            base = (localPath as NSString).lastPathComponent
        case .ssh:
            let path = (sshUrl as NSString).lastPathComponent
            base = path.isEmpty ? URL(string: sshUrl)?.host ?? "" : path
        }
        return base
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Create repo here"
        panel.message = "Choose an empty folder where the Borg repository will be initialized"
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
        }
    }

    // MARK: - Wizard

    private func runWizard() async {
        let finalName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            let suggested = suggestedName()
            return suggested.isEmpty ? "borg-repo" : suggested
        }()

        // Only carry the SSH key path for SSH repos.
        let keyPath: String? = (mode == .ssh) ? selectedKeyPath : nil

        do {
            step = .initializing
            try await BorgClient.shared.initRepo(
                url: location,
                passphrase: passphrase,
                encryption: encryption.rawValue,
                sshKeyPath: keyPath
            )

            step = .savingLocally
            let repo = Repository(
                name: finalName,
                url: location,
                sshKeyPath: keyPath
            )
            try store.add(repo, passphrase: passphrase)

            step = .done
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            step = .idle
        }
    }
}
