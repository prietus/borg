import SwiftUI
import AppKit

struct RepositoryDetailView: View {
    let repository: Repository

    @EnvironmentObject var statusStore: BackupRunStatusStore

    @State private var archives: [Archive] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selection: Archive.ID?

    @State private var showingBackup = false
    @State private var showingPrune = false
    @State private var showingSchedule = false
    @State private var showingPassphrase = false
    @State private var browsingArchive: Archive?
    @State private var treemapArchive: Archive?
    @State private var pendingDelete: Archive?
    @State private var deleting = false

    /// Live snapshot of whichever schedule of this repo is currently
    /// running. `nil` when no scheduled backup is in flight. Drives the
    /// banner + disables every borg operation on the detail view,
    /// since a write lock blocks `borg list`/`delete`/etc.
    private struct BusyContext {
        let schedule: BackupSchedule
        let status: BackupRunStatus
    }

    private var busyContext: BusyContext? {
        for schedule in repository.schedules {
            if let s = statusStore.status(for: schedule.id), s.running {
                return BusyContext(schedule: schedule, status: s)
            }
        }
        return nil
    }

    private var isBusy: Bool { busyContext != nil }

    @State private var pendingCancelSchedule: BackupSchedule?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let busy = busyContext {
                busyBanner(context: busy)
            }
            Divider()
            archivesTable
        }
        .navigationTitle(repository.name)
        .navigationSubtitle(repository.url)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingBackup = true
                } label: {
                    Label("New backup", systemImage: "plus.circle")
                }
                .disabled(isBusy)
                Button {
                    showingPrune = true
                } label: {
                    Label("Prune", systemImage: "scissors")
                }
                .disabled(isBusy)
                Button {
                    showingSchedule = true
                } label: {
                    Label("Schedule", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showingPassphrase = true
                } label: {
                    Label("Update passphrase", systemImage: "key.fill")
                }
                .help("Re-save the repo passphrase in the Keychain (needed by scheduled backups)")
                .disabled(isBusy)
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading || isBusy)
            }
        }
        .task(id: repository.id) {
            await refresh()
        }
        .onChange(of: isBusy) { _, nowBusy in
            // Transition busy → idle: backup finished, pull the fresh
            // archive list so the new archive appears without user
            // action. Guarded by `!nowBusy` so the initial busy tick
            // doesn't fire a doomed refresh.
            if !nowBusy {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showingBackup) {
            CreateBackupSheet(repository: repository) {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showingPrune) {
            PruneSheet(repository: repository) {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showingSchedule) {
            ScheduleSheet(repository: repository)
        }
        .sheet(isPresented: $showingPassphrase) {
            UpdatePassphraseSheet(repository: repository)
        }
        .sheet(item: $browsingArchive) { archive in
            ArchiveBrowserView(repository: repository, archive: archive)
        }
        .sheet(item: $treemapArchive) { archive in
            TreemapView(repository: repository, archive: archive)
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
        .confirmationDialog(
            pendingDelete.map { "Delete archive \($0.name)?" } ?? "Delete archive?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete archive", role: .destructive) {
                if let archive = pendingDelete {
                    Task { await delete(archive) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the archive from the repository immediately. The data it referenced stays on disk until you run Prune (which compacts) or a manual compact — space is not reclaimed until then.")
        }
        .confirmationDialog(
            pendingCancelSchedule.map { "Stop backup for \($0.displayName)?" } ?? "Stop backup?",
            isPresented: Binding(
                get: { pendingCancelSchedule != nil },
                set: { if !$0 { pendingCancelSchedule = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop backup", role: .destructive) {
                if let schedule = pendingCancelSchedule {
                    ScheduleManager.cancel(repoId: repository.id, scheduleId: schedule.id)
                }
                pendingCancelSchedule = nil
            }
            Button("Keep running", role: .cancel) { pendingCancelSchedule = nil }
        } message: {
            Text("Sends SIGTERM to borg. It writes a checkpoint and exits cleanly, so the repo stays consistent. The partial archive is discarded but the chunks already uploaded stay in the cache — the next run will reuse them.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name).font(.title3.bold())
                Text(repository.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding()
    }

    /// Non-modal banner shown while a scheduled backup is holding the
    /// repo lock. Replaces the error alert the user would otherwise
    /// see when `borg list` fails to acquire the lock mid-backup.
    /// Surfaces the live progress that the runner writes to the
    /// status file — same numbers as the menu bar row.
    private func busyBanner(context: BusyContext) -> some View {
        let status = context.status
        return HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Backup in progress")
                    .font(.callout.weight(.semibold))
                if let done = status.progressOriginalBytes,
                   let total = status.lastTotalOriginalBytes, total > 0 {
                    let ratio = min(1.0, Double(done) / Double(total))
                    ProgressView(value: ratio)
                        .tint(.orange)
                } else {
                    ProgressView()
                        .tint(.orange)
                }
                Text(busyDetailLine(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                pendingCancelSchedule = context.schedule
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop backup (SIGTERM to borg — leaves the repo consistent)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private func busyDetailLine(_ status: BackupRunStatus) -> String {
        var parts: [String] = []
        if let bytes = status.progressOriginalBytes, bytes > 0 {
            parts.append(Self.bytes.string(fromByteCount: bytes))
        }
        if let n = status.progressFileCount, n > 0 {
            parts.append("\(n) \(n == 1 ? "file" : "files")")
        }
        if let done = status.progressOriginalBytes,
           let total = status.lastTotalOriginalBytes, total > 0 {
            let ratio = min(1.0, Double(done) / Double(total))
            parts.append(String(format: "%.0f%%", ratio * 100))
        }
        if let path = status.progressCurrentPath, !path.isEmpty {
            parts.append(path)
        }
        if parts.isEmpty {
            return "Waiting for first progress tick…"
        }
        return parts.joined(separator: " · ")
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private var archivesTable: some View {
        Table(archives, selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Type") { archive in
                kindBadge(for: archive.name)
            }
            .width(min: 90, ideal: 100, max: 120)
            TableColumn("Date") { Text(formatDate($0.start)) }
            TableColumn("ID") {
                Text(String($0.archiveId.prefix(12)))
                    .font(.system(.body, design: .monospaced))
            }
        }
        .contextMenu(forSelectionType: Archive.ID.self) { ids in
            if let id = ids.first, let archive = archives.first(where: { $0.id == id }) {
                Button("Browse…") { browsingArchive = archive }
                Button("Analyze space…") { treemapArchive = archive }
                Divider()
                Button("Restore…") { restore(archive) }
                    .disabled(isBusy)
                Button("Mount…") { mount(archive) }
                    .disabled(isBusy)
                Divider()
                Button("Delete archive…", role: .destructive) {
                    pendingDelete = archive
                }
                .disabled(isBusy)
            }
        } primaryAction: { ids in
            if let id = ids.first, let archive = archives.first(where: { $0.id == id }) {
                browsingArchive = archive
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        // Borg holds an exclusive lock on the repo for the duration of
        // `borg create`, and `borg list` (what we call here) blocks/
        // errors when it can't grab the lock. Skip silently while a
        // scheduled backup is in flight — the busy→idle transition in
        // `.onChange(of: isBusy)` will kick a follow-up refresh once
        // the lock is released.
        if isBusy { return }
        loading = true
        defer { loading = false }
        do {
            archives = try await BorgClient.shared
                .listArchives(repo: repository)
                .sorted { $0.start > $1.start }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ archive: Archive) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore here"
        panel.message = "Pick the directory to restore the archive into"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await BorgClient.shared.extract(
                    repo: repository, archive: archive.name, into: url
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ archive: Archive) async {
        deleting = true
        defer { deleting = false }
        do {
            try await BorgClient.shared.deleteArchive(repo: repository, archive: archive.name)
            // Optimistic local removal so the row disappears before the
            // full refresh completes; `refresh` then reconciles in case
            // the delete failed partially.
            archives.removeAll { $0.id == archive.id }
            if selection == archive.id { selection = nil }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mount(_ archive: Archive) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Mount here"
        panel.message = "Pick an empty directory to mount the archive (requires macFUSE)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await BorgClient.shared.mount(
                    repo: repository, archive: archive.name, at: url
                )
                NSWorkspace.shared.open(url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func kindBadge(for name: String) -> some View {
        let kind = archiveKind(for: name)
        Text(kind.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(kind.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(kind.tint)
    }

    private enum ArchiveKind {
        case manual, scheduled, unknown
        var label: String {
            switch self {
            case .manual:    return "Manual"
            case .scheduled: return "Scheduled"
            case .unknown:   return "—"
            }
        }
        var tint: Color {
            switch self {
            case .manual:    return .blue
            case .scheduled: return .orange
            case .unknown:   return .secondary
            }
        }
    }

    private func archiveKind(for name: String) -> ArchiveKind {
        if name.hasPrefix("manual-") { return .manual }
        if name.hasPrefix("scheduled-") { return .scheduled }
        return .unknown
    }

    private func formatDate(_ raw: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        var date = input.date(from: raw)
        if date == nil {
            input.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            date = input.date(from: raw)
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}
