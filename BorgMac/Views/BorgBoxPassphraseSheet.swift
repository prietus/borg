import SwiftUI

/// Small modal asking the user for a Borg repo passphrase before running a
/// maintenance operation. Used by `BorgBoxServerPanel` when it couldn't
/// resolve the passphrase automatically from a matching local Repository.
struct BorgBoxPassphraseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repoName: String
    let action: String
    var onSubmit: (String) -> Void

    @State private var passphrase: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passphrase required").font(.title3.bold())
                    Text("\(action) · \(repoName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Text("The BorgBox daemon doesn't persist the passphrase — it's sent on every operation. It will be saved in the macOS Keychain so you don't have to re-enter it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 260)
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        onSubmit(passphrase)
        dismiss()
    }
}
