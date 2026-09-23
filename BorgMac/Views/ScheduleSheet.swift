import SwiftUI
import AppKit

// MARK: - List sheet (entry point from RepositoryDetailView)

struct ScheduleSheet: View {
    @EnvironmentObject var store: RepositoryStore
    @EnvironmentObject var statusStore: BackupRunStatusStore
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var editing: BackupSchedule?
    @State private var creatingNew: Bool = false
    @State private var pendingDelete: BackupSchedule?

    /// The schedules live on the repository in the store, not on local state —
    /// we always resolve the latest snapshot by repo id so edits from the
    /// editor sheet become visible immediately.
    private var schedules: [BackupSchedule] {
        store.repositories.first(where: { $0.id == repository.id })?.schedules ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if schedules.isEmpty {
                empty
            } else {
                list
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .sheet(item: $editing) { schedule in
            ScheduleEditorSheet(
                repositoryId: repository.id,
                existing: schedule
            )
        }
        .sheet(isPresented: $creatingNew) {
            ScheduleEditorSheet(
                repositoryId: repository.id,
                existing: nil
            )
        }
        .confirmationDialog(
            "Delete schedule \"\(pendingDelete?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete schedule", role: .destructive) {
                if let schedule = pendingDelete {
                    delete(schedule)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This unschedules the backup and removes its run history. The repository and existing archives are untouched.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedules").font(.title3.bold())
                Text(repository.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                creatingNew = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a new schedule")
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No schedules configured")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Create one to back up a set of paths on its own frequency.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(schedules) { schedule in
                ScheduleRow(
                    schedule: schedule,
                    onRunNow: { runNow(schedule) },
                    onDelete: { pendingDelete = schedule }
                )
                .contentShape(Rectangle())
                .onTapGesture { editing = schedule }
                .contextMenu {
                    Button("Run now") { runNow(schedule) }
                    Button("Edit") { editing = schedule }
                    Button("Delete", role: .destructive) {
                        pendingDelete = schedule
                    }
                }
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

    private func delete(_ schedule: BackupSchedule) {
        var repo = store.repositories.first(where: { $0.id == repository.id }) ?? repository
        repo.schedules.removeAll { $0.id == schedule.id }
        ScheduleManager.uninstall(repoId: repository.id, scheduleId: schedule.id)
        BackupStatusFile.delete(for: schedule.id)
        store.update(repo)
        statusStore.refresh()
        WidgetSnapshotWriter.refreshSchedules(repoStore: store, statusStore: statusStore)
    }

    private func runNow(_ schedule: BackupSchedule) {
        do {
            try ScheduleManager.kickstart(repoId: repository.id, scheduleId: schedule.id)
            // The runner will write status to disk shortly; nudge the store
            // so the spinner shows up without waiting for the 60s poll tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                statusStore.refresh()
            }
        } catch {
            // launchctl errors typically mean the plist isn't loaded — the
            // schedule list shouldn't be in this state, but log it.
            print("kickstart failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Row

private struct ScheduleRow: View {
    @EnvironmentObject var statusStore: BackupRunStatusStore
    let schedule: BackupSchedule
    var onRunNow: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                }
                .buttonStyle(.plain)
                .help("Delete schedule")
                .offset(x: 6, y: -4)
            }
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.displayName)
                    .font(.body.weight(.medium))
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let status = statusStore.status(for: schedule.id), status.running == true {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    onRunNow()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Run now")
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch schedule.frequency {
        case .hourly: return "clock"
        case .daily:  return "sun.max"
        case .weekly: return "calendar"
        }
    }

    private var summaryLine: String {
        let freq: String
        switch schedule.frequency {
        case .hourly: freq = "every hour"
        case .daily:  freq = String(format: "every day at %02d:%02d", schedule.hour, schedule.minute)
        case .weekly:
            let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let day = days[max(0, min(6, schedule.weekday))]
            freq = String(format: "every %@ at %02d:%02d", day, schedule.hour, schedule.minute)
        }
        let pathCount = schedule.paths.count
        let pathText = pathCount == 1 ? "1 path" : "\(pathCount) paths"
        return "\(freq) · \(pathText)"
    }
}

// MARK: - Editor sheet (create or edit a single schedule)

struct ScheduleEditorSheet: View {
    @EnvironmentObject var store: RepositoryStore
    @EnvironmentObject var statusStore: BackupRunStatusStore
    @Environment(\.dismiss) private var dismiss

    let repositoryId: UUID
    let existing: BackupSchedule?

    @State private var name: String
    @State private var frequency: BackupSchedule.Frequency
    @State private var weekday: Int
    @State private var timeOfDay: Date
    @State private var paths: [String]
    @State private var excludes: [String]
    @State private var newExcludePattern: String = ""
    @State private var keepDaily: Int
    @State private var keepWeekly: Int
    @State private var keepMonthly: Int
    @State private var error: String?
    @State private var busy = false

    init(repositoryId: UUID, existing: BackupSchedule?) {
        self.repositoryId = repositoryId
        self.existing = existing
        let s = existing ?? BackupSchedule()
        _name        = State(initialValue: s.name)
        _frequency   = State(initialValue: s.frequency)
        _weekday     = State(initialValue: s.weekday)
        _paths       = State(initialValue: s.paths)
        _excludes    = State(initialValue: s.excludes)
        _keepDaily   = State(initialValue: s.keepDaily)
        _keepWeekly  = State(initialValue: s.keepWeekly)
        _keepMonthly = State(initialValue: s.keepMonthly)

        var comps = DateComponents()
        comps.hour = s.hour
        comps.minute = s.minute
        _timeOfDay = State(
            initialValue: Calendar.current.date(from: comps) ?? Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New schedule" : "Edit schedule")
                .font(.title3.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    nameSection
                    configForm
                    pathsSection
                    excludesSection
                    retentionSection
                }
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 540, height: 620)
    }

    @ViewBuilder
    private var nameSection: some View {
        TextField("Name (optional)", text: $name, prompt: Text("e.g. Photos daily"))
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var configForm: some View {
        GroupBox("When") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Frequency", selection: $frequency) {
                    ForEach(BackupSchedule.Frequency.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                if frequency == .weekly {
                    Picker("Day", selection: $weekday) {
                        Text("Sunday").tag(0)
                        Text("Monday").tag(1)
                        Text("Tuesday").tag(2)
                        Text("Wednesday").tag(3)
                        Text("Thursday").tag(4)
                        Text("Friday").tag(5)
                        Text("Saturday").tag(6)
                    }
                }

                if frequency != .hourly {
                    DatePicker(
                        "Time",
                        selection: $timeOfDay,
                        displayedComponents: .hourAndMinute
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var pathsSection: some View {
        GroupBox("Paths to back up") {
            VStack(alignment: .leading, spacing: 6) {
                if paths.isEmpty {
                    Text("No paths yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                paths.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("Add…") { addPath() }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var excludesSection: some View {
        GroupBox("Exclude") {
            VStack(alignment: .leading, spacing: 6) {
                if excludes.isEmpty {
                    Text("No exclusion patterns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(excludes.enumerated()), id: \.offset) { idx, pattern in
                        HStack {
                            Image(systemName: "nosign")
                                .foregroundStyle(.secondary)
                            Text(pattern)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                excludes.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    TextField("Pattern (e.g. **/node_modules)", text: $newExcludePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitNewExclude() }
                    Button("Add") { commitNewExclude() }
                        .controlSize(.small)
                        .disabled(newExcludePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    Button {
                        pickExcludePaths()
                    } label: {
                        Label("Add from disk…", systemImage: "folder.badge.minus")
                    }
                    .controlSize(.small)
                    .help("Pick files or folders from Finder. Handy when you don't remember the exact patterns — the real names (not localized Finder names) get added as absolute paths.")

                    Button("Add common presets") { addPresetExcludes() }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Opens an NSOpenPanel in multi-select mode and adds each chosen
    /// path as an absolute exclude. Skips duplicates so the user can
    /// run this repeatedly without polluting the list. Complements —
    /// does not replace — the free-form text field, which is still the
    /// only way to add glob patterns like `**/node_modules`.
    private func pickExcludePaths() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Pick the files and folders you want to exclude from this backup."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !excludes.contains(path) {
                excludes.append(path)
            }
        }
    }

    private func commitNewExclude() {
        let trimmed = newExcludePattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !excludes.contains(trimmed) {
            excludes.append(trimmed)
        }
        newExcludePattern = ""
    }

    private func addPresetExcludes() {
        for preset in BackupSchedule.commonExcludePresets where !excludes.contains(preset) {
            excludes.append(preset)
        }
    }

    @ViewBuilder
    private var retentionSection: some View {
        GroupBox("Retention (optional)") {
            HStack(spacing: 16) {
                retentionStepper(title: "Daily", value: $keepDaily, range: 0...365)
                retentionStepper(title: "Weekly", value: $keepWeekly, range: 0...52)
                retentionStepper(title: "Monthly", value: $keepMonthly, range: 0...60)
            }
            .padding(.vertical, 4)
        }
    }

    private func retentionStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit())
            }
        }
    }

    // MARK: - Actions

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !paths.contains(url.path) {
            paths.append(url.path)
        }
    }

    private func save() {
        busy = true
        defer { busy = false }
        error = nil

        guard !paths.isEmpty else {
            error = "Add at least one path."
            return
        }

        guard var repo = store.repositories.first(where: { $0.id == repositoryId }) else {
            error = "Repository not found."
            return
        }

        let comps = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
        var schedule = existing ?? BackupSchedule()
        schedule.name = name.trimmingCharacters(in: .whitespaces)
        schedule.frequency = frequency
        schedule.hour = comps.hour ?? 3
        schedule.minute = comps.minute ?? 0
        schedule.weekday = weekday
        schedule.paths = paths
        schedule.excludes = excludes
        schedule.keepDaily = keepDaily
        schedule.keepWeekly = keepWeekly
        schedule.keepMonthly = keepMonthly

        do {
            try ScheduleManager.install(repoId: repositoryId, schedule: schedule)
            if let idx = repo.schedules.firstIndex(where: { $0.id == schedule.id }) {
                repo.schedules[idx] = schedule
            } else {
                repo.schedules.append(schedule)
            }
            store.update(repo)
            statusStore.refresh()
            WidgetSnapshotWriter.refreshSchedules(repoStore: store, statusStore: statusStore)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
