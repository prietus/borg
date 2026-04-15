import Foundation
import SwiftUI

/// Static helpers for reading and writing BackupRunStatus JSON files. These
/// are deliberately non-isolated so both the GUI (main actor) and the
/// headless `--run-backup` runner can touch them without boilerplate.
///
/// Status files are keyed by `scheduleId`, not by repo, because a single
/// repo can have multiple schedules with independent run histories.
enum BackupStatusFile {
    static var dir: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("BorgMac/status", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for scheduleId: UUID) -> URL {
        dir.appendingPathComponent("\(scheduleId.uuidString).json")
    }

    static func read(for scheduleId: UUID) -> BackupRunStatus? {
        let url = url(for: scheduleId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupRunStatus.self, from: data)
    }

    static func write(_ status: BackupRunStatus, for scheduleId: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: url(for: scheduleId), options: .atomic)
    }

    static func delete(for scheduleId: UUID) {
        try? FileManager.default.removeItem(at: url(for: scheduleId))
    }
}

/// Observable store that the menu bar and detail views subscribe to.
/// Polls the status dir on an adaptive cadence: 60 s when idle so the
/// store doesn't wake the disk for nothing, and 2 s while any schedule
/// is mid-run so the live progress bar in the menu bar follows `borg`
/// closely.
@MainActor
final class BackupRunStatusStore: ObservableObject {
    /// Keyed by `BackupSchedule.id`.
    @Published private(set) var statuses: [UUID: BackupRunStatus] = [:]

    private static let idleInterval: TimeInterval = 60
    private static let runningInterval: TimeInterval = 2

    private var timer: Timer?
    private var currentInterval: TimeInterval = BackupRunStatusStore.idleInterval

    init() {
        refresh()
        scheduleTimer(interval: Self.idleInterval)
    }

    deinit {
        timer?.invalidate()
    }

    func status(for scheduleId: UUID) -> BackupRunStatus? {
        statuses[scheduleId]
    }

    func refresh() {
        let dir = BackupStatusFile.dir
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let previous = statuses
        var next: [UUID: BackupRunStatus] = [:]
        for url in entries where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else { continue }
            if var status = BackupStatusFile.read(for: id) {
                // Liveness check: if a status claims to be running but
                // the runner pid is gone (crashed, OS reboot, SIGKILL,
                // killed before the signal handler got to run), rewrite
                // it as failed so the UI doesn't show a phantom "in
                // progress" forever. `kill(pid, 0)` is the standard
                // POSIX "is this pid alive" probe.
                if status.running, Self.isRunnerDead(status) {
                    status.running = false
                    status.attempt = nil
                    status.maxAttempts = nil
                    status.runnerPid = nil
                    status.progressOriginalBytes = nil
                    status.progressCompressedBytes = nil
                    status.progressDedupedBytes = nil
                    status.progressFileCount = nil
                    status.progressCurrentPath = nil
                    status.progressUpdatedAt = nil
                    status.progressStartedAt = nil
                    status.lastRun = Date()
                    status.lastError = "backup process died without finishing"
                    BackupStatusFile.write(status, for: id)
                }
                next[id] = status
            }
        }
        statuses = next

        // Any time the on-disk status picture actually moves (a run
        // started, ended, errored, or saw new progress), nudge the
        // widget so its "next backup" footer and health dot don't
        // lag behind reality until the user opens the stats panel.
        // Reads repositories.json directly — the store that owns the
        // list is a separate @MainActor type we'd have to plumb in
        // here otherwise.
        if next != previous {
            WidgetSnapshotWriter.refreshSchedulesFromDisk(statuses: next)
        }

        // Bump the cadence up or down based on whether any schedule is
        // currently running. The new interval takes effect on the next
        // tick — good enough given we're only swapping between 2 s and
        // 60 s.
        let anyRunning = next.values.contains { $0.running }
        let desired: TimeInterval = anyRunning ? Self.runningInterval : Self.idleInterval
        if desired != currentInterval {
            scheduleTimer(interval: desired)
        }
    }

    /// Returns true when the status's `runnerPid` is no longer a live
    /// process. `kill(pid, 0)` sends no signal but performs the usual
    /// permission/existence check: returns 0 if alive, or -1 with
    /// errno=ESRCH if the pid no longer maps to any process (and
    /// errno=EPERM if it maps to a process we can't signal, which also
    /// counts as "alive" — only ESRCH means dead).
    ///
    /// Absence of a pid is also treated as dead: status files written
    /// by binaries from before the runnerPid field existed get cleaned
    /// up on first GUI refresh, so a stale "running: true" from a
    /// pre-fix build doesn't wedge the UI forever.
    private static func isRunnerDead(_ status: BackupRunStatus) -> Bool {
        guard let pid = status.runnerPid, pid > 0 else { return true }
        if kill(pid, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
