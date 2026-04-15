import Foundation

enum ScheduleError: LocalizedError {
    case launchctlFailed(Int32, String)
    case executableMissing

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let code, let msg):
            return "launchctl failed (code \(code)): \(msg)"
        case .executableMissing:
            return "Could not determine the path to the BorgMac binary."
        }
    }
}

/// Installs / removes launchd User Agents that trigger scheduled backups by
/// invoking the BorgMac binary with `--run-backup <repo-id> <schedule-id>`.
///
/// Labels are scoped by both the repo UUID and the schedule UUID so a single
/// repo can host multiple jobs with independent frequencies and path sets.
enum ScheduleManager {
    static let labelPrefix = "com.carlos.BorgMac.backup."

    static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BorgMac", isDirectory: true)
    }

    static func label(repoId: UUID, scheduleId: UUID) -> String {
        "\(labelPrefix)\(repoId.uuidString).\(scheduleId.uuidString)"
    }

    /// Legacy (single-schedule) label used before multi-job support landed.
    /// Only the migration path uses this.
    static func legacyLabel(repoId: UUID) -> String {
        labelPrefix + repoId.uuidString
    }

    static func plistURL(repoId: UUID, scheduleId: UUID) -> URL {
        launchAgentsDir.appendingPathComponent(label(repoId: repoId, scheduleId: scheduleId) + ".plist")
    }

    static func legacyPlistURL(repoId: UUID) -> URL {
        launchAgentsDir.appendingPathComponent(legacyLabel(repoId: repoId) + ".plist")
    }

    static func logURL(repoId: UUID, scheduleId: UUID) -> URL {
        logsDir.appendingPathComponent("backup-\(repoId.uuidString)-\(scheduleId.uuidString).log")
    }

    static func isInstalled(repoId: UUID, scheduleId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(repoId: repoId, scheduleId: scheduleId).path)
    }

    // MARK: - Install / uninstall

    static func install(repoId: UUID, schedule: BackupSchedule) throws {
        guard let binary = Bundle.main.executablePath else {
            throw ScheduleError.executableMissing
        }
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let plist = makePlist(repoId: repoId, schedule: schedule, binary: binary)
        let url = plistURL(repoId: repoId, scheduleId: schedule.id)
        try plist.write(to: url, atomically: true, encoding: .utf8)

        // Unload previous version of *this* schedule if already present.
        let lbl = label(repoId: repoId, scheduleId: schedule.id)
        _ = try? runLaunchctl(["bootout", "\(domain())/\(lbl)"])
        try runLaunchctl(["bootstrap", domain(), url.path])
    }

    static func uninstall(repoId: UUID, scheduleId: UUID) {
        let lbl = label(repoId: repoId, scheduleId: scheduleId)
        _ = try? runLaunchctl(["bootout", "\(domain())/\(lbl)"])
        try? FileManager.default.removeItem(at: plistURL(repoId: repoId, scheduleId: scheduleId))
    }

    /// Cascading uninstall when a repository is deleted — wipes every plist
    /// whose filename starts with `com.carlos.BorgMac.backup.<repoUUID>.`.
    static func uninstallAll(repoId: UUID) {
        let prefix = "\(labelPrefix)\(repoId.uuidString)"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: launchAgentsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            _ = try? runLaunchctl(["bootout", "\(domain())/\(name)"])
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes the pre-multi-job plist (`backup.<repoUUID>.plist`) if it
    /// still exists. Best-effort, only called during migration.
    static func uninstallLegacy(repoId: UUID) {
        let lbl = legacyLabel(repoId: repoId)
        _ = try? runLaunchctl(["bootout", "\(domain())/\(lbl)"])
        try? FileManager.default.removeItem(at: legacyPlistURL(repoId: repoId))
    }

    /// Triggers the launchd job for a schedule immediately, regardless of
    /// its calendar interval. Used by the "Run now" action in the schedule
    /// list. Throws on launchctl failure so the caller can surface it.
    static func kickstart(repoId: UUID, scheduleId: UUID) throws {
        let lbl = label(repoId: repoId, scheduleId: scheduleId)
        try runLaunchctl(["kickstart", "-p", "\(domain())/\(lbl)"])
    }

    /// Sends SIGTERM to the currently-running instance of a scheduled
    /// backup. Borg traps the signal, writes a checkpoint, and exits
    /// cleanly — the in-flight archive is discarded but the chunks
    /// already uploaded stay in the repo's chunk cache, so the next
    /// run picks up where this one left off. No-ops silently (via
    /// `try?`) when there's nothing running under that label.
    static func cancel(repoId: UUID, scheduleId: UUID) {
        let lbl = label(repoId: repoId, scheduleId: scheduleId)
        _ = try? runLaunchctl(["kill", "TERM", "\(domain())/\(lbl)"])
    }

    // MARK: - Next fire date

    /// Best-effort client-side prediction of the next firing. Not consulted
    /// by launchd — used only to display "próximo backup" in the UI.
    static func nextFireDate(for schedule: BackupSchedule, after date: Date = Date()) -> Date? {
        let cal = Calendar.current
        switch schedule.frequency {
        case .hourly:
            return cal.date(byAdding: .hour, value: 1, to: date)

        case .daily:
            var comps = cal.dateComponents([.year, .month, .day], from: date)
            comps.hour = schedule.hour
            comps.minute = schedule.minute
            guard let candidate = cal.date(from: comps) else { return nil }
            if candidate > date { return candidate }
            return cal.date(byAdding: .day, value: 1, to: candidate)

        case .weekly:
            // launchd Weekday: 0 = Sunday … 6 = Saturday.
            // Calendar.weekday: 1 = Sunday … 7 = Saturday.
            let targetCalWeekday = schedule.weekday + 1
            let currentWeekday = cal.component(.weekday, from: date)
            let daysAhead = (targetCalWeekday - currentWeekday + 7) % 7
            guard let base = cal.date(byAdding: .day, value: daysAhead, to: date) else { return nil }
            var candComps = cal.dateComponents([.year, .month, .day], from: base)
            candComps.hour = schedule.hour
            candComps.minute = schedule.minute
            guard let candidate = cal.date(from: candComps) else { return nil }
            if candidate > date { return candidate }
            return cal.date(byAdding: .day, value: 7, to: candidate)
        }
    }

    // MARK: - Plist generation

    private static func makePlist(repoId: UUID, schedule: BackupSchedule, binary: String) -> String {
        let log = logURL(repoId: repoId, scheduleId: schedule.id).path
        let scheduleXML: String

        switch schedule.frequency {
        case .hourly:
            scheduleXML = """
                <key>StartInterval</key>
                <integer>3600</integer>
            """
        case .daily:
            scheduleXML = """
                <key>StartCalendarInterval</key>
                <dict>
                    <key>Hour</key>
                    <integer>\(schedule.hour)</integer>
                    <key>Minute</key>
                    <integer>\(schedule.minute)</integer>
                </dict>
            """
        case .weekly:
            scheduleXML = """
                <key>StartCalendarInterval</key>
                <dict>
                    <key>Weekday</key>
                    <integer>\(schedule.weekday)</integer>
                    <key>Hour</key>
                    <integer>\(schedule.hour)</integer>
                    <key>Minute</key>
                    <integer>\(schedule.minute)</integer>
                </dict>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label(repoId: repoId, scheduleId: schedule.id))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>--run-backup</string>
                <string>\(repoId.uuidString)</string>
                <string>\(schedule.id.uuidString)</string>
            </array>
        \(scheduleXML)
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(log)</string>
            <key>StandardErrorPath</key>
            <string>\(log)</string>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>

        """
    }

    // MARK: - launchctl plumbing

    private static func domain() -> String {
        "gui/\(getuid())"
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw ScheduleError.launchctlFailed(p.terminationStatus, text)
        }
        return text
    }
}
