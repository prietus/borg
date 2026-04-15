import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject var store: RepositoryStore
    @EnvironmentObject var statusStore: BackupRunStatusStore
    @EnvironmentObject var manualBackupStore: ManualBackupStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !manualBackupStore.orderedJobs.isEmpty {
                manualBackupsSection
                Divider()
            }
            repoList
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Manual backups section

    private var manualBackupsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manual backups")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ForEach(manualBackupStore.orderedJobs) { job in
                manualBackupRow(job)
            }
        }
    }

    private func manualBackupRow(_ job: ManualBackupJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: manualIcon(for: job))
                .foregroundStyle(manualColor(for: job))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.repoName)
                    .font(.body)
                    .lineLimit(1)
                Text(job.archiveName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = job.errorMessage, job.status == .failed {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(manualSubtitle(for: job))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if job.status == .running {
                Button {
                    manualBackupStore.cancel(jobId: job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Cancel backup (SIGTERM to borg)")
            } else {
                Button {
                    manualBackupStore.dismiss(jobId: job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide from the list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func manualIcon(for job: ManualBackupJob) -> String {
        switch job.status {
        case .running:   return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func manualColor(for job: ManualBackupJob) -> Color {
        switch job.status {
        case .running:   return .orange
        case .succeeded: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        }
    }

    private func manualSubtitle(for job: ManualBackupJob) -> String {
        let elapsed = Self.relative.localizedString(for: job.startedAt, relativeTo: Date())
        switch job.status {
        case .running:   return "in progress · \(elapsed)"
        case .succeeded: return "completed \(elapsed)"
        case .failed:    return "failed \(elapsed)"
        case .cancelled: return "cancelled \(elapsed)"
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
            Text("BorgMac").font(.headline)
            Spacer()
            Text("\(store.repositories.count) repo\(store.repositories.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Repo list

    /// Rows displayed in the popover — one per repo, plus one per schedule
    /// inside each repo. Repos without schedules still get a single row so
    /// the user can jump to them.
    private struct RepoRowModel: Identifiable {
        let id: String
        let repo: Repository
        let schedule: BackupSchedule?
    }

    private var rowModels: [RepoRowModel] {
        var rows: [RepoRowModel] = []
        for repo in store.repositories {
            if repo.schedules.isEmpty {
                rows.append(RepoRowModel(id: repo.id.uuidString, repo: repo, schedule: nil))
            } else {
                for schedule in repo.schedules {
                    rows.append(RepoRowModel(
                        id: "\(repo.id.uuidString).\(schedule.id.uuidString)",
                        repo: repo,
                        schedule: schedule
                    ))
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private var repoList: some View {
        if store.repositories.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add from BorgMac…") { showMainWindow() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(spacing: 0) {
                ForEach(rowModels) { model in
                    row(model)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ model: RepoRowModel) -> some View {
        let status = model.schedule.flatMap { statusStore.status(for: $0.id) }
        let nextRun = model.schedule.flatMap { ScheduleManager.nextFireDate(for: $0) }
        let running = status?.running == true && model.schedule != nil

        return Button {
            store.pendingSelection = model.repo.id
            showMainWindow()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: status))
                    .foregroundStyle(color(for: status))
                    .frame(width: 18)
                    .help(status?.lastError ?? "")
                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryLabel(model))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.repo.url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if status?.running == true {
                        progressBlock(status: status)
                    } else if let err = status?.lastError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(err)
                    } else if let scheduleLine = scheduleLine(status: status, nextRun: nextRun) {
                        Text(scheduleLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if running, let schedule = model.schedule {
                    Button {
                        ScheduleManager.cancel(repoId: model.repo.id, scheduleId: schedule.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop backup (SIGTERM to borg)")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// Compact "in-progress" block for a running scheduled backup.
    /// Renders a determinate progress bar when we know the previous
    /// run's total (so we can compute a percent), an indeterminate bar
    /// when we don't, plus a single text line with bytes/files/path.
    @ViewBuilder
    private func progressBlock(status: BackupRunStatus?) -> some View {
        if let status {
            VStack(alignment: .leading, spacing: 2) {
                if let done = status.progressOriginalBytes,
                   let total = status.lastTotalOriginalBytes, total > 0 {
                    let ratio = min(1.0, Double(done) / Double(total))
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .frame(height: 4)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .frame(height: 4)
                }
                Text(progressLine(status))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 2)
        }
    }

    /// Builds the single-line "12,345 files · 4.2 GB · 42% · /foo" text
    /// beneath the progress bar. Each piece is optional so early ticks
    /// (borg hasn't reported numbers yet) degrade gracefully.
    private func progressLine(_ status: BackupRunStatus) -> String {
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
        } else if let attempt = status.attempt, let max = status.maxAttempts, attempt > 1 {
            parts.append("retry \(attempt)/\(max)")
        }
        if let path = status.progressCurrentPath, !path.isEmpty {
            parts.append(path)
        }
        if parts.isEmpty {
            return "starting…"
        }
        return parts.joined(separator: " · ")
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private func primaryLabel(_ model: RepoRowModel) -> String {
        if let schedule = model.schedule {
            return "\(model.repo.name) · \(schedule.displayName)"
        }
        return model.repo.name
    }

    private func icon(for status: BackupRunStatus?) -> String {
        if status?.running == true { return "arrow.triangle.2.circlepath" }
        if status?.lastError != nil { return "exclamationmark.triangle.fill" }
        return "externaldrive.fill"
    }

    private func color(for status: BackupRunStatus?) -> Color {
        if status?.running == true { return .orange }
        if status?.lastError != nil { return .red }
        return .accentColor
    }

    private func scheduleLine(status: BackupRunStatus?, nextRun: Date?) -> String? {
        // Active retry takes precedence over last/next summary.
        if status?.running == true,
           let attempt = status?.attempt,
           let max = status?.maxAttempts,
           attempt > 1 {
            return "retrying \(attempt)/\(max)…"
        }
        var parts: [String] = []
        if let last = status?.lastRun {
            parts.append("last \(Self.relative.localizedString(for: last, relativeTo: Date()))")
        }
        if let next = nextRun {
            parts.append("next \(Self.relative.localizedString(for: next, relativeTo: Date()))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuButton(label: "New on BorgBase…", systemImage: "wand.and.stars") {
                openWindow(id: "wizard")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton(label: "New on BorgBox…", systemImage: "server.rack") {
                openWindow(id: "borgbox-wizard")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton(label: "New Borg repository (local or SSH)…", systemImage: "wand.and.stars.inverse") {
                openWindow(id: "borg-wizard")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton(label: "Show BorgMac", systemImage: "macwindow") {
                showMainWindow()
            }
            menuButton(label: "Quit", systemImage: "power", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func menuButton(
        label: String,
        systemImage: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .if(shortcut != nil) { view in
            view.keyboardShortcut(shortcut!, modifiers: .command)
        }
    }

    // MARK: - Main window activation

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                          ? Color.accentColor.opacity(0.25)
                          : Color.clear)
                    .padding(.horizontal, 6)
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
