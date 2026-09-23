import SwiftUI

// MARK: - List sheet (entry point from BorgBoxServerPanel repo row)

struct BorgBoxAlertsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: BorgBoxServer
    let repo: String

    @State private var alerts: [BorgBoxAlert] = []
    @State private var loading = false
    @State private var error: String?
    @State private var editing: BorgBoxAlert?
    @State private var creating = false
    @State private var pendingDelete: BorgBoxAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if loading && alerts.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if alerts.isEmpty {
                empty
            } else {
                list
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await refresh() }
        .sheet(item: $editing) { existing in
            BorgBoxAlertEditorSheet(
                server: server,
                repo: repo,
                existing: existing
            ) { _ in
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $creating) {
            BorgBoxAlertEditorSheet(
                server: server,
                repo: repo,
                existing: nil
            ) { _ in
                Task { await refresh() }
            }
        }
        .confirmationDialog(
            "Delete this alert?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete alert", role: .destructive) {
                if let alert = pendingDelete {
                    Task { await delete(alert) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The webhook URL won't receive any further stale notifications for this repo.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stale alerts").font(.title3.bold())
                Text(repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help("Refresh")

            Button {
                creating = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No alerts configured")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Get notified via a webhook when this repo hasn't received a backup in a while.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(alerts) { alert in
                BorgBoxAlertRow(
                    server: server,
                    alert: alert,
                    onEdit: { editing = alert },
                    onDelete: { pendingDelete = alert },
                    onToggle: { newValue in
                        Task { await toggle(alert, enabled: newValue) }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { editing = alert }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            alerts = try await BorgBoxClient.shared.alertsForRepo(
                server: server,
                repo: repo
            )
        } catch BorgBoxError.http(404, _) {
            error = "The daemon doesn't implement alerts yet. Update BorgBox to use them."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ alert: BorgBoxAlert, enabled: Bool) async {
        do {
            _ = try await BorgBoxClient.shared.updateAlert(
                server: server,
                id: alert.id,
                enabled: enabled
            )
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ alert: BorgBoxAlert) async {
        do {
            try await BorgBoxClient.shared.deleteAlert(server: server, id: alert.id)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct BorgBoxAlertRow: View {
    let server: BorgBoxServer
    let alert: BorgBoxAlert
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onToggle: (Bool) -> Void

    @State private var testing = false
    /// The last test result, shown inline for a few seconds. Kept local to
    /// the row so a retest on another alert doesn't stomp this one's state.
    @State private var testOutcome: TestOutcome?

    private enum TestOutcome: Equatable {
        case ok
        case failed(String)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stateIcon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.webhookURL)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !alert.enabled {
                        Text("Disabled")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if alert.hasSecret {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                            Text("Signed")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                        .help("Webhook deliveries are HMAC-signed with this alert's secret.")
                    }
                }
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let outcome = testOutcome {
                    testOutcomeLabel(outcome)
                }
                if !alert.lastError.isEmpty {
                    Text(alert.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { alert.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Menu {
                Button("Edit") { onEdit() }
                Button("Test webhook") { Task { await test() } }
                    .disabled(testing)
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateIcon: some View {
        // Switching over `String?` with literal cases is safe in Swift
        // (they desugar to .some("ok") / .some("stale")); default catches
        // nil and any unexpected value the daemon might emit in future.
        switch alert.lastState {
        case "ok":
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case "stale":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        default:
            Image(systemName: "bell")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func testOutcomeLabel(_ outcome: TestOutcome) -> some View {
        switch outcome {
        case .ok:
            Label("Webhook responded OK", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        parts.append("stale after \(alert.staleAfterHours)h")
        if alert.renotifyHours > 0 {
            parts.append("re-notify every \(alert.renotifyHours)h")
        } else {
            parts.append("edge-triggered")
        }
        if let date = alert.lastCheckDate {
            parts.append("checked \(Self.relative(from: date))")
        }
        return parts.joined(separator: " · ")
    }

    private static func relative(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            try await BorgBoxClient.shared.testAlert(server: server, id: alert.id)
            testOutcome = .ok
        } catch let BorgBoxError.apiError(msg) {
            testOutcome = .failed(msg)
        } catch let BorgBoxError.http(code, body) {
            testOutcome = .failed("HTTP \(code): \(body)")
        } catch {
            testOutcome = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Editor sheet (create or edit a single alert)

struct BorgBoxAlertEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: BorgBoxServer
    let repo: String
    let existing: BorgBoxAlert?
    var onSaved: (BorgBoxAlert) -> Void

    @State private var staleAfterHours: Int
    @State private var webhookURL: String
    @State private var enabled: Bool
    @State private var renotifyHours: Int
    @State private var secret: String = ""
    /// Set to true when editing an alert that has a secret and the user
    /// wants to stop signing. If the secret field is left empty on save,
    /// this triggers a `secret: ""` PATCH (clear) instead of omission.
    @State private var clearSigning: Bool = false
    @State private var busy = false
    @State private var error: String?

    init(
        server: BorgBoxServer,
        repo: String,
        existing: BorgBoxAlert?,
        onSaved: @escaping (BorgBoxAlert) -> Void
    ) {
        self.server = server
        self.repo = repo
        self.existing = existing
        self.onSaved = onSaved
        _staleAfterHours = State(initialValue: existing?.staleAfterHours ?? 26)
        _webhookURL      = State(initialValue: existing?.webhookURL ?? "")
        _enabled         = State(initialValue: existing?.enabled ?? true)
        _renotifyHours   = State(initialValue: existing?.renotifyHours ?? 0)
    }

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
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New alert" : "Edit alert")
                    .font(.title3.bold())
                Text(repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var form: some View {
        Form {
            Section("Trigger") {
                Stepper(
                    "Stale after \(staleAfterHours) h",
                    value: $staleAfterHours,
                    in: 1...720
                )
                Stepper(
                    renotifyHours == 0
                        ? "Re-notify: never (edge-triggered)"
                        : "Re-notify every \(renotifyHours) h",
                    value: $renotifyHours,
                    in: 0...720
                )
                Toggle("Enabled", isOn: $enabled)
            }
            Section {
                TextField(
                    "Webhook URL",
                    text: $webhookURL,
                    prompt: Text("https://ntfy.sh/your-topic")
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            } footer: {
                Text("The daemon POSTs a JSON event (`stale` / `recovered` / `test`) to this URL. ntfy.sh topics work out of the box; any URL that accepts POST and returns 2xx is fine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            signingSection
        }
        .formStyle(.grouped)
    }

    /// Signing secret UI. Three shapes depending on mode:
    ///  • Create                → plain SecureField, "optional" prompt.
    ///  • Edit, no secret yet   → same as create (non-destructive to enable).
    ///  • Edit, already signed  → placeholder explains that leaving empty
    ///    keeps the current secret; a "Stop signing" toggle below lets the
    ///    user explicitly clear it on save.
    @ViewBuilder
    private var signingSection: some View {
        let alreadySigned = existing?.hasSecret == true
        Section {
            SecureField(
                alreadySigned ? "New secret (leave empty to keep current)"
                              : "Signing secret (optional)",
                text: $secret
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(clearSigning)
            if alreadySigned {
                Toggle("Stop signing (clear current secret)", isOn: $clearSigning)
            }
        } header: {
            Text("Webhook signing")
        } footer: {
            Text("If set, BorgBox adds `X-BorgBox-Signature: sha256=<hmac>` to every webhook POST so the receiver can verify the call came from your daemon. Leave empty for unsigned deliveries.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Create" : "Save") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || !isValid)
        }
    }

    private var isValid: Bool {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespaces)
        guard staleAfterHours > 0, !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil

        let trimmedURL = webhookURL.trimmingCharacters(in: .whitespaces)
        let typedSecret = secret // don't trim — spaces could be intentional in a secret
        do {
            let saved: BorgBoxAlert
            if let existing {
                // PATCH: three wire states for the secret.
                //  nil → omit → daemon keeps current secret.
                //  ""  → clear → daemon stops signing.
                //  "x" → set/rotate.
                let secretPayload: String?
                if clearSigning {
                    secretPayload = ""
                } else if !typedSecret.isEmpty {
                    secretPayload = typedSecret
                } else {
                    secretPayload = nil
                }
                saved = try await BorgBoxClient.shared.updateAlert(
                    server: server,
                    id: existing.id,
                    staleAfterHours: staleAfterHours,
                    webhookURL: trimmedURL,
                    enabled: enabled,
                    renotifyHours: renotifyHours,
                    secret: secretPayload
                )
            } else {
                saved = try await BorgBoxClient.shared.createAlert(
                    server: server,
                    repo: repo,
                    staleAfterHours: staleAfterHours,
                    webhookURL: trimmedURL,
                    enabled: enabled,
                    renotifyHours: renotifyHours,
                    secret: typedSecret.isEmpty ? nil : typedSecret
                )
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
