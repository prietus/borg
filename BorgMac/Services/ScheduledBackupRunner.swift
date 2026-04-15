import Foundation

/// Headless entry point used when BorgMac is invoked by launchd with
/// `--run-backup <repo-uuid> <schedule-uuid>`. Loads the repository and the
/// specific schedule from the on-disk store, reads the passphrase
/// non-interactively from the keychain, runs `borg create` (and optional
/// `prune`) with a retry loop, writes a status file that the GUI picks up.
enum ScheduledBackupRunner {
    static let maxAttempts = 3
    /// Delays per attempt index (after attempts 1 and 2). Exponential: 60s, 120s.
    static let retryDelaysSec: [Int] = [60, 120]

    // MARK: - Cancellation bookkeeping
    //
    // The menu bar cancel button fires `launchctl kill TERM` at our
    // launchd job, which sends SIGTERM to *this* Swift process. Without
    // a handler the process dies immediately, the borg subprocess is
    // orphaned (reparented to launchd — it keeps writing to the repo
    // until the SSH connection drops on its own, or forever for a local
    // repo), and the status file stays `running: true` because
    // `finalizeFailure` never gets to run. From the user's perspective
    // the backup is stuck forever and only deleting the app helps.
    //
    // So we install a SIGTERM/SIGINT handler that:
    //   1. Kills the borg child (whose pid is tracked here while it's
    //      alive).
    //   2. Writes a "cancelled by user" status.
    //   3. Exits non-zero so launchd records a failure.

    private static let cancelLock = NSLock()
    private static var currentBorgPid: pid_t = 0
    private static var currentRepoId: UUID?
    private static var currentScheduleId: UUID?
    private static var currentRepoName: String = "?"
    private static var currentScheduleName: String = "?"
    private static var cancelRequested = false
    private static var termSource: DispatchSourceSignal?
    private static var intSource: DispatchSourceSignal?

    static func run(repoIdString: String, scheduleIdString: String) -> Never {
        fputs("[\(Date())] BorgMac scheduled run starting for repo=\(repoIdString) schedule=\(scheduleIdString)\n", stdout)

        guard let repoId = UUID(uuidString: repoIdString),
              let scheduleId = UUID(uuidString: scheduleIdString) else {
            fputs("invalid uuid arguments\n", stderr)
            exit(2)
        }
        installSignalHandlers()
        let success = perform(repoId: repoId, scheduleId: scheduleId)
        fputs("[\(Date())] BorgMac scheduled run finished — success=\(success)\n", stdout)
        exit(success ? 0 : 1)
    }

    /// Installs a dispatch-source-backed handler for SIGTERM/SIGINT.
    /// Must be called once at process startup. The default disposition
    /// of the signals is set to `SIG_IGN` first because Dispatch signal
    /// sources layer on top of the signal delivery — without that
    /// `SIG_DFL` terminates the process before the source fires.
    private static func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "borgmac.runner.signals")
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { handleCancel(signalName: "SIGTERM") }
        term.resume()
        termSource = term
        let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        int.setEventHandler { handleCancel(signalName: "SIGINT") }
        int.resume()
        intSource = int
    }

    private static func handleCancel(signalName: String) {
        cancelLock.lock()
        if cancelRequested {
            cancelLock.unlock()
            return
        }
        cancelRequested = true
        let pid = currentBorgPid
        let scheduleId = currentScheduleId
        let repoId = currentRepoId
        let repoName = currentRepoName
        let scheduleName = currentScheduleName
        cancelLock.unlock()

        fputs("[\(Date())] received \(signalName) — cancelling backup (borg pid=\(pid))\n", stderr)

        if pid > 0 {
            // Borg traps SIGTERM and writes a checkpoint before exiting,
            // so the repo stays consistent and the cache keeps the
            // already-uploaded chunks for the next run to reuse.
            kill(pid, SIGTERM)
        }

        if let scheduleId, let repoId {
            writeCancelledStatus(
                scheduleId: scheduleId, repoId: repoId,
                repoName: repoName, scheduleName: scheduleName
            )
        }
        // exit(130) right away. No sleep — any pending progress write
        // from the throttle queue is best-effort and we want to minimise
        // the window where the main perform() loop could re-enter
        // `markAttempt` and overwrite the cancelled status.
        exit(130)
    }

    /// Writes the "cancelled" status file without going through
    /// `finalizeFailure`, which would also try to post a user
    /// notification — a dispatch that can block the signal handler
    /// queue on osascript and widen the race with the main thread.
    /// The GUI picks up the status via its normal poll.
    private static func writeCancelledStatus(
        scheduleId: UUID, repoId: UUID,
        repoName: String, scheduleName: String
    ) {
        var status = BackupStatusFile.read(for: scheduleId) ?? BackupRunStatus()
        status.running = false
        status.attempt = nil
        status.maxAttempts = nil
        status.runnerPid = nil
        status.lastRun = Date()
        status.lastError = "cancelled by user"
        status.progressOriginalBytes = nil
        status.progressCompressedBytes = nil
        status.progressDedupedBytes = nil
        status.progressFileCount = nil
        status.progressCurrentPath = nil
        status.progressUpdatedAt = nil
        status.progressStartedAt = nil
        BackupStatusFile.write(status, for: scheduleId)
    }

    private static func perform(repoId: UUID, scheduleId: UUID) -> Bool {
        guard let repo = loadRepository(id: repoId) else {
            finalizeFailure(
                scheduleId: scheduleId, repoId: repoId, repoName: "?",
                scheduleName: "?",
                error: "repository not found in repositories.json"
            )
            return false
        }
        guard let schedule = repo.schedules.first(where: { $0.id == scheduleId }) else {
            finalizeFailure(
                scheduleId: scheduleId, repoId: repoId, repoName: repo.name,
                scheduleName: "?",
                error: "schedule \(scheduleId) no longer exists in the repository"
            )
            return false
        }
        guard schedule.paths.isEmpty == false else {
            finalizeFailure(
                scheduleId: scheduleId, repoId: repoId, repoName: repo.name,
                scheduleName: schedule.displayName,
                error: "the schedule has no paths"
            )
            return false
        }
        guard let passphrase = Keychain.unattendedPassphrase(for: repoId) else {
            finalizeFailure(
                scheduleId: scheduleId, repoId: repoId, repoName: repo.name,
                scheduleName: schedule.displayName,
                error: "passphrase not available in the keychain"
            )
            return false
        }

        // Publish the run context so the SIGTERM handler can write a
        // finalizeFailure with proper names instead of "?".
        cancelLock.lock()
        currentRepoId = repoId
        currentScheduleId = scheduleId
        currentRepoName = repo.name
        currentScheduleName = schedule.displayName
        cancelLock.unlock()

        // Fresh archive name per retry. Earlier we reused a single name
        // under the assumption that a failed borg create never commits,
        // but in practice borg can commit the archive and still exit
        // non-zero (e.g. SSH banner noise from BorgBase triggers warnings
        // on stderr and a code-1/2 exit). Reusing the name then turned
        // retries into "Archive ... already exists" failures that masked
        // what was really a successful run. Borg's chunk-level dedup
        // means retrying with a new name is effectively free — any
        // chunks already uploaded by the previous attempt are reused.
        var lastError = "unknown error"
        var archive = archiveName(scheduleName: schedule.name)

        for attempt in 1...maxAttempts {
            if isCancelled() {
                fputs("[\(Date())] cancelled — aborting retry loop\n", stderr)
                return false
            }
            markAttempt(scheduleId: scheduleId, attempt: attempt, max: maxAttempts)
            fputs("[\(Date())] attempt \(attempt)/\(maxAttempts) — borg create ::\(archive)\n", stdout)

            let (success, errText) = runAttempt(
                repo: repo,
                schedule: schedule,
                passphrase: passphrase,
                archive: archive
            )

            if success {
                finalizeSuccess(
                    scheduleId: scheduleId, repoId: repoId,
                    repoName: repo.name,
                    scheduleName: schedule.displayName,
                    archive: archive, attempt: attempt
                )
                return true
            }

            // If the failure was "archive already exists" it means a
            // previous attempt (this run, a racing process, or even the
            // scheduled launchd run firing in parallel with a manual
            // kickstart) actually committed that archive. Treat it as
            // success rather than burning the rest of the retries.
            if let errText, errText.localizedCaseInsensitiveContains("already exists") {
                fputs("[\(Date())] archive \(archive) already exists — treating as success\n", stdout)
                finalizeSuccess(
                    scheduleId: scheduleId, repoId: repoId,
                    repoName: repo.name,
                    scheduleName: schedule.displayName,
                    archive: archive, attempt: attempt
                )
                return true
            }

            lastError = errText ?? "unknown error"
            fputs("[\(Date())] attempt \(attempt) failed: \(lastError)\n", stderr)

            if attempt < maxAttempts {
                let delay = retryDelaysSec[attempt - 1]
                fputs("[\(Date())] retrying in \(delay)s\n", stdout)
                Thread.sleep(forTimeInterval: TimeInterval(delay))
                archive = archiveName(scheduleName: schedule.name)
            }
        }

        if isCancelled() {
            // The signal handler already wrote the cancelled status —
            // don't clobber it with a different error message.
            return false
        }

        finalizeFailure(
            scheduleId: scheduleId, repoId: repoId,
            repoName: repo.name,
            scheduleName: schedule.displayName,
            error: lastError
        )
        return false
    }

    private static func isCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    /// Runs a single borg create (plus optional prune) attempt. Returns
    /// (success, errorMessageOnFailure). Prune failures do NOT fail the
    /// attempt — the backup itself has already committed by that point.
    private static func runAttempt(
        repo: Repository,
        schedule: BackupSchedule,
        passphrase: String,
        archive: String
    ) -> (success: Bool, error: String?) {
        let sem = DispatchSemaphore(value: 0)
        var success = false
        var errorText: String?

        // Throttle status-file writes to ~1 Hz. Borg emits progress
        // events much faster than that on large trees, and each write
        // is an atomic rename — no point hammering the disk when the
        // menu bar polls at 2 s.
        let throttle = ProgressThrottle(
            scheduleId: schedule.id,
            minInterval: 1.0
        )
        let onProgress: @Sendable (BorgProgress) -> Void = { progress in
            throttle.submit(progress)
        }
        let onLaunch: @Sendable (pid_t) -> Void = { pid in
            cancelLock.lock()
            currentBorgPid = pid
            let alreadyCancelled = cancelRequested
            cancelLock.unlock()
            // Covers the tiny race where a SIGTERM arrived between
            // installSignalHandlers() and borg actually starting: the
            // first handler call had pid=0 and couldn't kill anything.
            // Propagate the signal now that we know the pid.
            if alreadyCancelled {
                kill(pid, SIGTERM)
            }
        }

        Task.detached {
            do {
                try await BorgClient.shared.createBackupUnattended(
                    repo: repo,
                    passphrase: passphrase,
                    archiveName: archive,
                    paths: schedule.paths,
                    excludes: schedule.excludes,
                    onProgress: onProgress,
                    onLaunch: onLaunch
                )
                if schedule.keepDaily > 0 || schedule.keepWeekly > 0 || schedule.keepMonthly > 0 {
                    do {
                        try await BorgClient.shared.pruneUnattended(
                            repo: repo,
                            passphrase: passphrase,
                            keepDaily: schedule.keepDaily,
                            keepWeekly: schedule.keepWeekly,
                            keepMonthly: schedule.keepMonthly
                        )
                    } catch {
                        fputs("prune failed: \(error.localizedDescription)\n", stderr)
                    }
                }
                success = true
            } catch {
                errorText = error.localizedDescription
            }
            sem.signal()
        }
        sem.wait()
        // Borg is gone — clear the tracked pid so a cancel during the
        // retry sleep doesn't try to signal a stale or reused pid.
        cancelLock.lock()
        currentBorgPid = 0
        cancelLock.unlock()
        return (success, errorText)
    }

    // MARK: - Repository loading (duplicates the minimal path that the GUI
    // store uses — we can't instantiate @MainActor types from here).

    private static func loadRepository(id: UUID) -> Repository? {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = support.appendingPathComponent("BorgMac/repositories.json")
        guard let data = try? Data(contentsOf: url),
              let repos = try? JSONDecoder().decode([Repository].self, from: data) else {
            return nil
        }
        return repos.first { $0.id == id }
    }

    private static func archiveName(scheduleName: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        // Milliseconds keep two nearly-simultaneous runs (launchd firing
        // a scheduled run while the user hits "Run now", or a quick
        // retry) from generating the same archive name.
        df.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let stamp = df.string(from: Date())
        let slug = scheduleName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return slug.isEmpty ? "scheduled-\(stamp)" : "scheduled-\(slug)-\(stamp)"
    }

    // MARK: - Status updates

    private static func markAttempt(scheduleId: UUID, attempt: Int, max: Int) {
        var status = BackupStatusFile.read(for: scheduleId) ?? BackupRunStatus()
        status.running = true
        status.attempt = attempt
        status.maxAttempts = max
        // Stamp the runner pid so the GUI can detect stale "running"
        // statuses whose owning process is no longer alive (crashed,
        // killed, OS reboot mid-backup).
        status.runnerPid = getpid()
        // Reset live-progress fields at the start of every attempt so
        // the UI doesn't carry stale data from the previous try.
        clearProgressFields(&status)
        status.progressStartedAt = Date()
        BackupStatusFile.write(status, for: scheduleId)
    }

    private static func clearProgressFields(_ status: inout BackupRunStatus) {
        status.progressOriginalBytes = nil
        status.progressCompressedBytes = nil
        status.progressDedupedBytes = nil
        status.progressFileCount = nil
        status.progressCurrentPath = nil
        status.progressUpdatedAt = nil
        status.progressStartedAt = nil
    }

    private static func finalizeSuccess(
        scheduleId: UUID,
        repoId: UUID,
        repoName: String,
        scheduleName: String,
        archive: String,
        attempt: Int
    ) {
        var status = BackupStatusFile.read(for: scheduleId) ?? BackupRunStatus()
        // Remember this run's final byte count so the next run's UI
        // can compute a percentage against it.
        if let bytes = status.progressOriginalBytes, bytes > 0 {
            status.lastTotalOriginalBytes = bytes
        }
        status.running = false
        status.attempt = nil
        status.maxAttempts = nil
        status.runnerPid = nil
        status.lastRun = Date()
        status.lastSuccess = Date()
        status.lastArchiveName = archive
        status.lastError = nil
        clearProgressFields(&status)
        BackupStatusFile.write(status, for: scheduleId)

        var subtitle = "\(repoName) / \(scheduleName)"
        if attempt > 1 { subtitle += " (attempt \(attempt))" }
        Notifications.postSuccess(repoName: subtitle, archiveName: archive)
    }

    private static func finalizeFailure(
        scheduleId: UUID,
        repoId: UUID,
        repoName: String,
        scheduleName: String,
        error: String
    ) {
        var status = BackupStatusFile.read(for: scheduleId) ?? BackupRunStatus()
        status.running = false
        status.attempt = nil
        status.maxAttempts = nil
        status.runnerPid = nil
        status.lastRun = Date()
        status.lastError = error
        clearProgressFields(&status)
        BackupStatusFile.write(status, for: scheduleId)

        Notifications.postFailure(
            repoName: "\(repoName) / \(scheduleName)",
            repoId: repoId,
            scheduleId: scheduleId,
            errorMessage: error,
            logPath: ScheduleManager.logURL(repoId: repoId, scheduleId: scheduleId).path
        )
    }
}

/// Coalesces high-frequency `BorgProgress` events into bounded-rate
/// writes of the status JSON. `borg --progress --log-json` can fire
/// dozens of events per second on a tree of many small files; without
/// a throttle we'd rewrite the same file constantly and starve disk
/// I/O that belongs to the backup itself. Thread-safe because borg's
/// line handler runs on a background pipe queue.
final class ProgressThrottle: @unchecked Sendable {
    private let scheduleId: UUID
    private let minInterval: TimeInterval
    private let lock = NSLock()
    private var lastWrite: Date = .distantPast

    init(scheduleId: UUID, minInterval: TimeInterval) {
        self.scheduleId = scheduleId
        self.minInterval = minInterval
    }

    func submit(_ progress: BorgProgress) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= minInterval else {
            lock.unlock()
            return
        }
        lastWrite = now
        lock.unlock()

        var status = BackupStatusFile.read(for: scheduleId) ?? BackupRunStatus()
        status.running = true
        status.progressOriginalBytes = progress.originalBytes
        status.progressCompressedBytes = progress.compressedBytes
        status.progressDedupedBytes = progress.dedupedBytes
        status.progressFileCount = progress.fileCount
        status.progressCurrentPath = progress.currentPath
        status.progressUpdatedAt = now
        BackupStatusFile.write(status, for: scheduleId)
    }
}
