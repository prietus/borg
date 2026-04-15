import SwiftUI

struct PruneSheet: View {
    let repository: Repository
    var onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keepDaily = 7
    @State private var keepWeekly = 4
    @State private var keepMonthly = 6
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prune")
                .font(.title2.bold())
            Text("Deletes archives according to a retention policy. Set 0 to disable a rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Stepper("Keep daily: \(keepDaily)", value: $keepDaily, in: 0...365)
                Stepper("Keep weekly: \(keepWeekly)", value: $keepWeekly, in: 0...104)
                Stepper("Keep monthly: \(keepMonthly)", value: $keepMonthly, in: 0...120)
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(running)
                Button("Run prune") { runPrune() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func runPrune() {
        running = true
        error = nil
        Task {
            defer { running = false }
            do {
                try await BorgClient.shared.prune(
                    repo: repository,
                    keepDaily: keepDaily,
                    keepWeekly: keepWeekly,
                    keepMonthly: keepMonthly
                )
                onCompleted()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
