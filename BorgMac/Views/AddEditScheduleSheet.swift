import SwiftUI

/// Create / edit form for a BorgBox maintenance schedule. Presented as a
/// sheet from `AutomationPanel`. The parent supplies the server (picked
/// from the "Add schedule" menu) and an optional existing schedule; when
/// nil the sheet is in create mode and loads the server's repo list so
/// the user can pick a target.
///
/// The weekday / day fields are shown conditionally based on cadence, so
/// the user never has to manipulate a dummy value. On save we send only
/// the fields the daemon actually uses for that cadence — the server
/// ignores unused ones but being explicit avoids stale weekday/day values
/// sticking around after an edit flipped cadence.
struct AddEditScheduleSheet: View {
    let server: BorgBoxServer
    let existing: BorgBoxSchedule?
    let defaultRepo: String?
    /// Fired after a successful create/update with the schedule the
    /// daemon returned — parent uses this to upsert the row in-place
    /// instead of re-fetching the whole list.
    let onSaved: (BorgBoxSchedule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: String = "check"
    @State private var cadence: String = "weekly"
    @State private var hour: Int = 3
    @State private var minute: Int = 0
    @State private var weekday: Int = 0
    @State private var day: Int = 1
    @State private var enabled: Bool = true
    @State private var repo: String = ""

    /// Available repos for the current server, fetched on first appear
    /// when in create mode. In edit mode we don't need this — the repo
    /// is locked to the existing schedule's repo.
    @State private var repos: [BorgBoxRemoteRepo] = []
    @State private var loadingRepos = false
    @State private var saving = false
    @State private var error: String?

    private static let kinds: [(String, String)] = [
        ("check", "Check (verify repo integrity)"),
        ("compact", "Compact (reclaim deleted segments)")
    ]

    private static let cadences: [(String, String)] = [
        ("daily", "Daily"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly")
    ]

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !saving && !repo.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Target") {
                    LabeledContent("Server") {
                        Text(server.name).foregroundStyle(.secondary)
                    }
                    if isEditing {
                        LabeledContent("Repository") {
                            Text(repo)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Repository", selection: $repo) {
                            if repo.isEmpty {
                                Text(loadingRepos ? "Loading…" : "Select a repo…")
                                    .tag("")
                            }
                            ForEach(repos) { r in
                                Text(r.name).tag(r.name)
                            }
                        }
                        .disabled(loadingRepos || repos.isEmpty)
                    }
                }

                Section("Job") {
                    Picker("Kind", selection: $kind) {
                        ForEach(Self.kinds, id: \.0) { pair in
                            Text(pair.1).tag(pair.0)
                        }
                    }
                    Picker("Cadence", selection: $cadence) {
                        ForEach(Self.cadences, id: \.0) { pair in
                            Text(pair.1).tag(pair.0)
                        }
                    }
                    if cadence == "weekly" {
                        Picker("Day of week", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { i in
                                Text(Self.weekdayNames[i]).tag(i)
                            }
                        }
                    }
                    if cadence == "monthly" {
                        Picker("Day of month", selection: $day) {
                            ForEach(1..<29, id: \.self) { i in
                                Text("\(i)").tag(i)
                            }
                        }
                        .help("1–28 only, to avoid missing short months.")
                    }
                    HStack {
                        Picker("Hour", selection: $hour) {
                            ForEach(0..<24, id: \.self) { i in
                                Text(String(format: "%02d", i)).tag(i)
                            }
                        }
                        Picker("Minute", selection: $minute) {
                            ForEach(0..<60, id: \.self) { i in
                                Text(String(format: "%02d", i)).tag(i)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $enabled)
                } footer: {
                    Text(footerHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 0)

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { await onAppear() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEditing ? "pencil.circle" : "plus.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit schedule" : "New schedule")
                    .font(.title3.bold())
                Text("Runs on the BorgBox daemon — no client involvement needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Create") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footerHelp: String {
        if cadence == "weekly" {
            return "Fires every \(Self.weekdayNames[weekday]) at \(String(format: "%02d:%02d", hour, minute)) in the server's local time. If a previous job is still running when the tick arrives, this one is skipped and retried on the next tick."
        }
        if cadence == "monthly" {
            return "Fires on day \(day) of each month at \(String(format: "%02d:%02d", hour, minute)). Day values above 28 aren't accepted so short months don't silently miss."
        }
        return "Fires every day at \(String(format: "%02d:%02d", hour, minute)) in the server's local time."
    }

    // MARK: - Lifecycle

    private func onAppear() async {
        if let existing {
            kind = existing.kind
            cadence = existing.cadence
            hour = existing.hour
            minute = existing.minute
            weekday = existing.weekday
            day = max(existing.day, 1)
            enabled = existing.enabled
            repo = existing.repo
            return
        }

        if let defaultRepo {
            repo = defaultRepo
        }

        loadingRepos = true
        defer { loadingRepos = false }
        do {
            let fetched = try await BorgBoxClient.shared.listRepos(server: server)
            repos = fetched.filter { $0.isRegistered }
            if repo.isEmpty, let first = repos.first {
                repo = first.name
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil

        do {
            let saved: BorgBoxSchedule
            if let existing {
                saved = try await BorgBoxClient.shared.updateSchedule(
                    server: server,
                    id: existing.id,
                    kind: kind,
                    cadence: cadence,
                    hour: hour,
                    minute: minute,
                    weekday: cadence == "weekly" ? weekday : nil,
                    day: cadence == "monthly" ? day : nil,
                    enabled: enabled
                )
            } else {
                saved = try await BorgBoxClient.shared.createSchedule(
                    server: server,
                    repo: repo,
                    kind: kind,
                    cadence: cadence,
                    hour: hour,
                    minute: minute,
                    weekday: cadence == "weekly" ? weekday : 0,
                    day: cadence == "monthly" ? day : 0,
                    enabled: enabled
                )
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
