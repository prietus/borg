import SwiftUI

/// Global overview of every maintenance schedule registered on every
/// configured BorgBox server. Fetches fresh data from each daemon on open
/// and after any create/update/delete so the table stays in sync with the
/// server state without needing a long-lived store.
///
/// Only covers BorgBox-side schedules (check / compact). Local-repo
/// `BackupSchedule` entries live in `RepositoryStore` and are surfaced
/// elsewhere; mixing both kinds in one table would conflate very
/// different lifecycles.
struct AutomationPanel: View {
    @EnvironmentObject var borgBoxStore: BorgBoxServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [ScheduleRow] = []
    @State private var loading = false
    @State private var error: String?

    /// Schedule editor sheet state — one sheet serves both create and
    /// edit, with `nil` existing meaning "create".
    @State private var editorTarget: EditorTarget?

    /// Confirmation dialog state for destructive delete.
    @State private var pendingDelete: ScheduleRow?

    /// Row id of the schedule whose `enabled` toggle is in flight, to
    /// disable further clicks and show a spinner.
    @State private var togglingId: String?

    /// Flat denormalised row — one per schedule across all servers. Built
    /// from `BorgBoxSchedule` plus the server it came from so the table
    /// can show both columns without a second lookup.
    private struct ScheduleRow: Identifiable, Hashable {
        let server: BorgBoxServer
        let schedule: BorgBoxSchedule
        var id: String { "\(server.id.uuidString)::\(schedule.id)" }
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let server: BorgBoxServer
        /// When non-nil, the sheet is in edit mode.
        let existing: BorgBoxSchedule?
        /// Default repo name for create mode. Ignored in edit mode.
        let defaultRepo: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 880, height: 620)
        .task { await load() }
        .sheet(item: $editorTarget) { target in
            AddEditScheduleSheet(
                server: target.server,
                existing: target.existing,
                defaultRepo: target.defaultRepo
            ) { saved in
                upsert(server: target.server, schedule: saved)
            }
            .environmentObject(borgBoxStore)
        }
        .confirmationDialog(
            "Delete schedule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    Task { await delete(row) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let row = pendingDelete {
                Text("This removes the \(row.schedule.kind) schedule for \(row.schedule.repo) on \(row.server.name). The daemon stops firing it immediately.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automation").font(.title3.bold())
                Text("Scheduled maintenance on your BorgBox servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !borgBoxStore.servers.isEmpty {
                Menu {
                    ForEach(borgBoxStore.servers) { server in
                        Button(server.name) {
                            editorTarget = EditorTarget(
                                server: server,
                                existing: nil,
                                defaultRepo: nil
                            )
                        }
                    }
                } label: {
                    Label("Add schedule…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(loading)
                .help("Create a new schedule on one of your BorgBox servers")
            }
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(loading)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if borgBoxStore.servers.isEmpty {
            ContentUnavailableView(
                "No BorgBox servers",
                systemImage: "server.rack",
                description: Text("Add a BorgBox server from the sidebar to create maintenance schedules.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading && rows.isEmpty {
            ProgressView("Loading schedules…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No schedules yet", systemImage: "clock.badge.questionmark")
            } description: {
                Text("Nothing is scheduled on any of your BorgBox servers. Create one to get weekly check or compact runs.")
            } actions: {
                if let first = borgBoxStore.servers.first {
                    Button("Add schedule…") {
                        editorTarget = EditorTarget(
                            server: first,
                            existing: nil,
                            defaultRepo: nil
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            Table(rows) {
                TableColumn("Server") { row in
                    Text(row.server.name).font(.body)
                }
                .width(min: 100, ideal: 130)

                TableColumn("Repo") { row in
                    Text(row.schedule.repo)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 100, ideal: 140)

                TableColumn("Kind") { row in
                    HStack(spacing: 4) {
                        Image(systemName: iconForKind(row.schedule.kind))
                            .foregroundStyle(.tint)
                        Text(row.schedule.kind.capitalized)
                    }
                }
                .width(min: 80, ideal: 90)

                TableColumn("Cadence") { row in
                    Text(cadenceDescription(row.schedule))
                }
                .width(min: 130, ideal: 160)

                TableColumn("Next") { row in
                    Text(nextRunLabel(row.schedule))
                        .foregroundStyle(row.schedule.enabled ? .primary : .secondary)
                        .help(absoluteDateTooltip(row.schedule.nextRunDate))
                }
                .width(min: 110, ideal: 130)

                TableColumn("Last") { row in
                    lastRunCell(row.schedule)
                }
                .width(min: 110, ideal: 140)

                TableColumn("Enabled") { row in
                    Toggle("", isOn: Binding(
                        get: { row.schedule.enabled },
                        set: { newValue in
                            Task { await toggleEnabled(row, to: newValue) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(togglingId == row.id)
                    .help(row.schedule.enabled ? "Pause this schedule" : "Resume this schedule")
                }
                .width(60)

                TableColumn("Actions") { row in
                    HStack(spacing: 6) {
                        Button {
                            editorTarget = EditorTarget(
                                server: row.server,
                                existing: row.schedule,
                                defaultRepo: nil
                            )
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit schedule")

                        Button(role: .destructive) {
                            pendingDelete = row
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete schedule")
                    }
                }
                .width(min: 70, ideal: 80)
            }
        }
    }

    private func lastRunCell(_ schedule: BorgBoxSchedule) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconForStatus(schedule.lastStatus))
                .foregroundStyle(colorForStatus(schedule.lastStatus))
                .font(.caption)
            Text(lastRunLabel(schedule))
                .foregroundStyle(.secondary)
        }
        .help(lastRunTooltip(schedule))
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil

        var collected: [ScheduleRow] = []
        var failures: [String] = []

        for server in borgBoxStore.servers {
            do {
                let schedules = try await BorgBoxClient.shared.listSchedules(server: server)
                for schedule in schedules {
                    collected.append(ScheduleRow(server: server, schedule: schedule))
                }
            } catch {
                failures.append("\(server.name): \(error.localizedDescription)")
            }
        }

        Self.sortRows(&collected)
        rows = collected
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func toggleEnabled(_ row: ScheduleRow, to newValue: Bool) async {
        togglingId = row.id
        defer { togglingId = nil }
        do {
            let updated = try await BorgBoxClient.shared.updateSchedule(
                server: row.server,
                id: row.schedule.id,
                enabled: newValue
            )
            upsert(server: row.server, schedule: updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ row: ScheduleRow) async {
        do {
            try await BorgBoxClient.shared.deleteSchedule(
                server: row.server,
                id: row.schedule.id
            )
            rows.removeAll { $0.id == row.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Replaces the existing row for the same (server, schedule id) pair
    /// or inserts a new one, then re-sorts. Called after a successful
    /// create/update so we never round-trip a full GET just to pick up
    /// one row the daemon already returned.
    private func upsert(server: BorgBoxServer, schedule: BorgBoxSchedule) {
        let newRow = ScheduleRow(server: server, schedule: schedule)
        if let idx = rows.firstIndex(where: { $0.id == newRow.id }) {
            rows[idx] = newRow
        } else {
            rows.append(newRow)
        }
        Self.sortRows(&rows)
    }

    private static func sortRows(_ rows: inout [ScheduleRow]) {
        rows.sort { a, b in
            if a.server.name != b.server.name {
                return a.server.name.localizedStandardCompare(b.server.name) == .orderedAscending
            }
            if a.schedule.repo != b.schedule.repo {
                return a.schedule.repo.localizedStandardCompare(b.schedule.repo) == .orderedAscending
            }
            return a.schedule.kind < b.schedule.kind
        }
    }

    // MARK: - Formatting helpers

    private func iconForKind(_ kind: String) -> String {
        switch kind {
        case "check":   return "checkmark.shield"
        case "compact": return "shippingbox.and.arrow.backward"
        default:        return "gearshape"
        }
    }

    private func cadenceDescription(_ s: BorgBoxSchedule) -> String {
        let time = String(format: "%02d:%02d", s.hour, s.minute)
        switch s.cadence {
        case "daily":
            return "Daily at \(time)"
        case "weekly":
            return "\(Self.weekdayName(s.weekday)) at \(time)"
        case "monthly":
            return "Day \(s.day) at \(time)"
        default:
            return "\(s.cadence) at \(time)"
        }
    }

    private static func weekdayName(_ n: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard n >= 0 && n < names.count else { return "—" }
        return names[n]
    }

    private func nextRunLabel(_ s: BorgBoxSchedule) -> String {
        guard s.enabled else { return "Paused" }
        guard let date = s.nextRunDate else { return "—" }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    private func lastRunLabel(_ s: BorgBoxSchedule) -> String {
        if s.lastStatus == "running" { return "running…" }
        guard let date = s.lastRunDate else { return "never" }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    private func lastRunTooltip(_ s: BorgBoxSchedule) -> String {
        if s.lastRun.isEmpty {
            return "This schedule has never fired."
        }
        var parts: [String] = []
        if let date = s.lastRunDate {
            parts.append(Self.absolute.string(from: date))
        }
        switch s.lastStatus {
        case "done":    parts.append("Completed successfully.")
        case "running": parts.append("Currently running.")
        case "error":   parts.append("Last run failed.")
        case "skipped": parts.append("Skipped: repo wasn't on disk at fire time.")
        default: break
        }
        if !s.lastJobId.isEmpty {
            parts.append("Job: \(s.lastJobId)")
        }
        return parts.joined(separator: "\n")
    }

    private func absoluteDateTooltip(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.absolute.string(from: date)
    }

    private func iconForStatus(_ status: String) -> String {
        switch status {
        case "done":    return "checkmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath"
        case "error":   return "exclamationmark.triangle.fill"
        case "skipped": return "exclamationmark.circle"
        default:        return "circle.dotted"
        }
    }

    private func colorForStatus(_ status: String) -> Color {
        switch status {
        case "done":    return .green
        case "running": return .orange
        case "error":   return .red
        case "skipped": return .yellow
        default:        return .secondary
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
