import SwiftUI

struct BorgBoxPruneSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: BorgBoxServer
    let repo: String
    let passphrase: String?
    var onStarted: (BorgBoxJobStart) -> Void

    @State private var keepDaily: Int = 7
    @State private var keepWeekly: Int = 4
    @State private var keepMonthly: Int = 12
    @State private var keepYearly: Int = 2
    @State private var dryRun: Bool = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            form
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 440, height: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Prune").font(.title3.bold())
                Text(repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var form: some View {
        Form {
            Section("Retention") {
                Stepper("Daily: \(keepDaily)", value: $keepDaily, in: 0...365)
                Stepper("Weekly: \(keepWeekly)", value: $keepWeekly, in: 0...52)
                Stepper("Monthly: \(keepMonthly)", value: $keepMonthly, in: 0...60)
                Stepper("Yearly: \(keepYearly)", value: $keepYearly, in: 0...20)
            }
            Section {
                Toggle("Dry run only (simulate)", isOn: $dryRun)
            } footer: {
                Text("With dry run on, borg lists what it would delete but doesn't touch anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(dryRun ? "Simulate prune" : "Run prune") { run() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let start = try await BorgBoxClient.shared.prune(
                    server: server,
                    repo: repo,
                    passphrase: passphrase,
                    keepDaily: keepDaily,
                    keepWeekly: keepWeekly,
                    keepMonthly: keepMonthly,
                    keepYearly: keepYearly,
                    dryRun: dryRun
                )
                onStarted(start)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
