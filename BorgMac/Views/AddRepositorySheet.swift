import SwiftUI

struct AddRepositorySheet: View {
    @EnvironmentObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String
    @State private var passphrase = ""
    @State private var sshKeyPath: String = ""
    @State private var availableKeys: [LocalSSHKey] = []
    @State private var error: String?

    init(initialName: String = "", initialUrl: String = "") {
        _name = State(initialValue: initialName)
        _url = State(initialValue: initialUrl)
    }

    private var isSSHURL: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("ssh://") || trimmed.contains("@")
    }

    private var canSave: Bool {
        if name.isEmpty || url.isEmpty { return false }
        if isSSHURL && sshKeyPath.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New repository")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. BorgBase Personal"))
                TextField("URL", text: $url, prompt: Text("ssh://user@host:port/./repo"))
                    .autocorrectionDisabled()
                SecureField("Passphrase", text: $passphrase)

                if isSSHURL {
                    Picker("SSH key", selection: $sshKeyPath) {
                        Text("— pick one —").tag("")
                        ForEach(availableKeys) { key in
                            Text(key.displayName).tag(key.privatePath)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            availableKeys = SSHKeyDiscovery.list()
        }
    }

    private var helpText: String {
        if isSSHURL {
            return "For SSH repos you **must** pick the specific private key authorized for this repo. Without this, ssh will try every key in the agent and may end up using the wrong one (and the daemon will reject the connection)."
        }
        return "For local repos use an absolute path. The passphrase is stored in the Keychain."
    }

    private func save() {
        let trimmedKey = sshKeyPath.trimmingCharacters(in: .whitespaces)
        let repo = Repository(
            name: name,
            url: url,
            sshKeyPath: trimmedKey.isEmpty ? nil : trimmedKey
        )
        do {
            try store.add(repo, passphrase: passphrase)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
