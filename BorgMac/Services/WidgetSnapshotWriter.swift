import Foundation
import WidgetKit

/// Bridge between the host app and the WidgetKit extension. The widget
/// is sandboxed-off just like the main app, so it reads
/// `WidgetSnapshot.fileURL` directly without an App Group — the writer's
/// only job is to keep that file current and nudge WidgetKit to pull.
///
/// Two entry points:
/// - `write(...)`  — full snapshot, called from `StatsPanel.load()` where
///   we already have fresh usage numbers per provider.
/// - `refreshSchedules(...)` — cheaper variant that reuses the previous
///   snapshot's usage fields and only recomputes `nextBackup` + `health`.
///   Called from `ScheduleManager.install / uninstall` so toggling a
///   schedule refreshes the widget footer without a full stats sweep.
@MainActor
enum WidgetSnapshotWriter {
    static func write(
        repoCount: Int,
        archiveCount: Int,
        totalUsageBytes: Int64,
        byProvider: [WidgetSnapshot.ProviderUsage],
        topRepos: [WidgetSnapshot.RepoUsage],
        repoStore: RepositoryStore,
        statusStore: BackupRunStatusStore
    ) {
        let (nextBackup, health) = summarizeSchedules(
            repositories: repoStore.repositories,
            statuses: statusStore.statuses
        )
        persist(WidgetSnapshot(
            generatedAt: Date(),
            repoCount: repoCount,
            archiveCount: archiveCount,
            totalUsageBytes: totalUsageBytes,
            byProvider: byProvider,
            topRepos: topRepos,
            nextBackup: nextBackup,
            health: health
        ))
    }

    /// Updates only the schedule-derived fields, reusing the last
    /// persisted usage numbers. Silently no-ops when no previous
    /// snapshot exists — the next `StatsPanel` load will create one.
    static func refreshSchedules(
        repoStore: RepositoryStore,
        statusStore: BackupRunStatusStore
    ) {
        refreshSchedules(
            repositories: repoStore.repositories,
            statuses: statusStore.statuses
        )
    }

    /// Same as `refreshSchedules(repoStore:statusStore:)` but takes the
    /// raw data so callers that don't hold the @MainActor stores (e.g.
    /// `BackupRunStatusStore.refresh()` reacting to a status-file change
    /// from the runner process) can nudge the widget without plumbing a
    /// cross-store reference.
    static func refreshSchedules(
        repositories: [Repository],
        statuses: [UUID: BackupRunStatus]
    ) {
        guard let previous = WidgetSnapshot.load() else { return }
        let (nextBackup, health) = summarizeSchedules(
            repositories: repositories,
            statuses: statuses
        )
        persist(WidgetSnapshot(
            generatedAt: Date(),
            repoCount: previous.repoCount,
            archiveCount: previous.archiveCount,
            totalUsageBytes: previous.totalUsageBytes,
            byProvider: previous.byProvider,
            topRepos: previous.topRepos,
            nextBackup: nextBackup,
            health: health
        ))
    }

    /// Reads `repositories.json` directly from disk (same path
    /// `RepositoryStore` persists to) and refreshes the schedule fields.
    /// Used by `BackupRunStatusStore` after a status file changes so the
    /// widget stays in sync with scheduled runs that finish while the
    /// main window / stats panel isn't open. Silently no-ops on any I/O
    /// or decode failure — the next `StatsPanel` load will recover.
    static func refreshSchedulesFromDisk(statuses: [UUID: BackupRunStatus]) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport
            .appendingPathComponent("BorgMac", isDirectory: true)
            .appendingPathComponent("repositories.json")
        guard let data = try? Data(contentsOf: url),
              let repos = try? JSONDecoder().decode([Repository].self, from: data) else {
            return
        }
        refreshSchedules(repositories: repos, statuses: statuses)
    }

    private static func persist(_ snapshot: WidgetSnapshot) {
        do {
            try snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("[WidgetSnapshotWriter] save failed: \(error)")
        }
    }

    /// Walks every repo's schedules, finds the soonest-firing enabled
    /// one, and derives a health flag from the run-status store. Uses
    /// `ScheduleManager.nextFireDate` so the prediction matches what
    /// the menu bar extra shows.
    private static func summarizeSchedules(
        repositories: [Repository],
        statuses: [UUID: BackupRunStatus]
    ) -> (WidgetSnapshot.NextBackup?, WidgetSnapshot.Health) {
        var soonest: WidgetSnapshot.NextBackup?
        var anyRunning = false
        var anyError = false
        let now = Date()

        for repo in repositories {
            for schedule in repo.schedules {
                let status = statuses[schedule.id]
                if status?.running == true { anyRunning = true }
                if status?.lastError != nil { anyError = true }

                guard let fire = ScheduleManager.nextFireDate(for: schedule, after: now) else {
                    continue
                }
                if soonest == nil || fire < soonest!.fireDate {
                    soonest = WidgetSnapshot.NextBackup(
                        repoName: repo.name,
                        scheduleName: schedule.displayName,
                        fireDate: fire
                    )
                }
            }
        }

        let health: WidgetSnapshot.Health
        if anyError       { health = .error }
        else if anyRunning { health = .running }
        else               { health = .ok }
        return (soonest, health)
    }
}
