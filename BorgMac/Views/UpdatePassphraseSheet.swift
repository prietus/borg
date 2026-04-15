import SwiftUI

/// Sheet that lets the user (re-)store the Borg passphrase for an existing
/// repository in the Keychain. Added because the scheduled runner needs a
/// non-interactive read path, and when the item is missing or was written
/// by an older build with a trusted-apps ACL the only way out used to be
/// deleting and re-adding the repo (losing its schedules).
///
/// Before writing to the Keychain we verify the passphrase by running
/// `borg info --json` with it — a wrong passphrase would otherwise just
/// mean the next scheduled run fails with "Invalid passphrase".
struct UpdatePassphraseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var passphrase: String = ""
    @State private var verifying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update passphrase").font(.title3.bold())
                    Text(repository.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Text("Stores the passphrase in the macOS Keychain so scheduled backups can open the repo without a prompt. The passphrase is verified against the repo before it's saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
                .disabled(verifying)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if verifying {
                    ProgressView().controlSize(.small)
                    Text("Verifying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(verifying)
                Button("Save") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(passphrase.isEmpty || verifying)
            }
        }
        .padding(20)
        .frame(width: 460, height: 280)
    }

    private func submit() {
        guard !passphrase.isEmpty, !verifying else { return }
        verifying = true
        error = nil
        Task {
            do {
                try await BorgClient.shared.verifyPassphrase(
                    repo: repository, passphrase: passphrase
                )
                try Keychain.setPassphrase(passphrase, for: repository.id)
                await BorgClient.shared.forget(repoId: repository.id)
                await MainActor.run {
                    verifying = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    verifying = false
                }
            }
        }
    }
}
