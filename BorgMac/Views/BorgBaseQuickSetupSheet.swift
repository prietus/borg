import SwiftUI

struct BorgBaseQuickSetupSheet: View {
    @EnvironmentObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var repoName: String = ""
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""
    @State private var region: Region = .eu
    @State private var token: String = ""
    @State private var hasStoredToken: Bool = false
    @State private var step: Step = .idle
    @State private var error: String?

    enum Region: String, CaseIterable, Identifiable {
        case eu, us
        var id: String { rawValue }
        var label: String {
            switch self {
            case .eu: return "Europe (Frankfurt / Helsinki)"
            case .us: return "United States"
            }
        }
    }

    enum Step: Equatable {
        case idle
        case generatingKey
        case uploadingKey
        case creatingRepo
        case initRepo
        case savingLocally
        case done(url: String)

        var label: String {
            switch self {
            case .idle: return ""
            case .generatingKey: return "Generating a dedicated SSH key…"
            case .uploadingKey: return "Uploading SSH key to BorgBase…"
            case .creatingRepo: return "Creating the repository on BorgBase…"
            case .initRepo: return "Initializing the Borg repository (borg init)…"
            case .savingLocally: return "Saving to BorgMac…"
            case .done: return "Done."
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
            if hasStoredToken {
                form
            } else {
                tokenEntry
            }
            if step != .idle {
                Divider()
                progressView
            }
            Spacer()
            footer
        }
        .padding(20)
        .frame(width: 560, height: 540)
        .task {
            hasStoredToken = await BorgBaseClient.shared.hasToken()
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

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("New repository on BorgBase").font(.title3.bold())
                Text("Generate an SSH key, create the repo on BorgBase, and run borg init in one step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                Text("Connect your BorgBase account")
                    .font(.headline)
            }
            Text("To create repos automatically I need an API token with write scope. Generate one at borgbase.com → Settings → Access Tokens, check the **Repository Add** and **SSH Key Add** scopes, and paste it here. It is stored in your local Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste your API token here", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Link("Open BorgBase",
                     destination: URL(string: "https://www.borgbase.com/settings/access_tokens")!)
                    .font(.caption)
                Spacer()
                Button("Connect") {
                    saveToken()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var form: some View {
        Form {
            Section("Repository") {
                TextField("Name", text: $repoName, prompt: Text("e.g. macbook-personal"))
                SecureField("Passphrase", text: $passphrase)
                SecureField("Repeat passphrase", text: $passphraseConfirm)
            }
            Section("Region") {
                Picker("Data center", selection: $region) {
                    ForEach(Region.allCases) { Text($0.label).tag($0) }
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
            if hasStoredToken {
                Button("Forget BorgBase token") {
                    Task {
                        await BorgBaseClient.shared.clearToken()
                        Keychain.deleteBorgBaseToken()
                        hasStoredToken = false
                    }
                }
                .buttonStyle(.borderless)
                .disabled(step.isRunning)
                .help("Remove the API token from this Mac. You'll need to paste it again to create more repos.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(step.isRunning)
            if hasStoredToken {
                Button("Create") { Task { await runWizard() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
    }

    private var canCreate: Bool {
        guard !step.isRunning, case .idle = step else { return false }
        let nameOk = !repoName.trimmingCharacters(in: .whitespaces).isEmpty
        let passOk = passphrase.count >= 1 && passphrase == passphraseConfirm
        return nameOk && passOk
    }

    // MARK: - Actions

    private func saveToken() {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.setBorgBaseToken(trimmed)
            Task {
                await BorgBaseClient.shared.setToken(trimmed)
                hasStoredToken = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runWizard() async {
        let cleanName = repoName.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty else { return }

        do {
            // 1. Generate SSH key
            step = .generatingKey
            let (privateKeyPath, publicKey) = try SSHKeyGen.generate(
                slug: cleanName,
                comment: "borgmac-\(cleanName)"
            )

            // 2. Upload to BorgBase
            step = .uploadingKey
            let added = try await BorgBaseClient.shared.addSSHKey(
                name: "BorgMac \(cleanName)",
                keyData: publicKey
            )

            // 3. Create repo on BorgBase
            step = .creatingRepo
            let createdRepo = try await BorgBaseClient.shared.createRepo(
                name: cleanName,
                fullAccessKeys: [added.id],
                region: region.rawValue
            )

            // 4. borg init
            step = .initRepo
            try await BorgClient.shared.initRepo(
                url: createdRepo.repoPath,
                passphrase: passphrase,
                sshKeyPath: privateKeyPath
            )

            // 5. Save locally
            step = .savingLocally
            let repo = Repository(
                name: createdRepo.name,
                url: createdRepo.repoPath,
                sshKeyPath: privateKeyPath
            )
            try store.add(repo, passphrase: passphrase)

            step = .done(url: createdRepo.repoPath)
            // Auto-dismiss after a short pause
            try? await Task.sleep(nanoseconds: 800_000_000)
            resetWizardState()
            dismiss()
        } catch BorgBaseError.unauthenticated {
            // The stored token is stale — wipe it and bounce the user back
            // to the token entry screen so they can paste a fresh one.
            Keychain.deleteBorgBaseToken()
            await BorgBaseClient.shared.clearToken()
            hasStoredToken = false
            token = ""
            self.error = "The BorgBase token is no longer valid. Paste a new one."
            step = .idle
        } catch {
            self.error = error.localizedDescription
            step = .idle
        }
    }

    private func resetWizardState() {
        repoName = ""
        passphrase = ""
        passphraseConfirm = ""
        step = .idle
        error = nil
    }
}
