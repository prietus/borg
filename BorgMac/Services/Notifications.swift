import Foundation
import UserNotifications
import AppKit

/// Thin wrapper around `UNUserNotificationCenter` for scheduled-backup
/// notifications. Works from both the GUI process and the headless
/// `--run-backup` runner because `UNUserNotificationCenter` resolves the
/// bundle identifier from `Bundle.main`, which is the same binary in both
/// cases.
enum Notifications {
    static let successCategoryId = "borgmac.backup.success"
    static let failureCategoryId = "borgmac.backup.failure"

    static let actionRetry  = "borgmac.backup.retry"
    static let actionOpenLog = "borgmac.backup.openLog"

    static let userInfoRepoId     = "repoId"
    static let userInfoScheduleId = "scheduleId"
    static let userInfoLogPath    = "logPath"

    /// Call once from the GUI at startup. Safe to call multiple times;
    /// after the first user decision `requestAuthorization` becomes a no-op.
    static func bootstrap() {
        registerCategories()
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Registers the two categories (success / failure) with their action
    /// buttons. Called from both the GUI (on startup) and the headless
    /// runner (before posting) — `setNotificationCategories` is idempotent.
    static func registerCategories() {
        let retry = UNNotificationAction(
            identifier: actionRetry,
            title: "Retry",
            options: []
        )
        let openLog = UNNotificationAction(
            identifier: actionOpenLog,
            title: "Open Log",
            options: [.foreground]
        )
        let failure = UNNotificationCategory(
            identifier: failureCategoryId,
            actions: [retry, openLog],
            intentIdentifiers: [],
            options: []
        )
        let success = UNNotificationCategory(
            identifier: successCategoryId,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current()
            .setNotificationCategories([success, failure])
    }

    // MARK: - Posting

    /// True when we're running inside the normal GUI process (NSApp is up).
    /// In that case `UNUserNotificationCenter` is the right path — it gives
    /// us action buttons and rich delivery. From the headless `--run-backup`
    /// runner the system notification center may silently drop requests, so
    /// we fall back to `osascript display notification` instead.
    private static var isGUIProcess: Bool {
        NSApp != nil
    }

    static func postSuccess(repoName: String, archiveName: String) {
        if isGUIProcess {
            let content = UNMutableNotificationContent()
            content.title = "Backup complete"
            content.subtitle = repoName
            content.body = archiveName
            content.categoryIdentifier = successCategoryId
            content.sound = .default
            deliverViaUN(content: content)
        } else {
            deliverViaOsascript(
                title: "Backup complete",
                subtitle: repoName,
                body: archiveName
            )
        }
    }

    /// Failure notification for a manual (non-scheduled) backup. Has no
    /// Retry action because there's no schedule plist to kickstart.
    static func postManualFailure(repoName: String, errorMessage: String) {
        if isGUIProcess {
            let content = UNMutableNotificationContent()
            content.title = "Manual backup failed"
            content.subtitle = repoName
            content.body = errorMessage
            content.sound = .default
            deliverViaUN(content: content)
        } else {
            deliverViaOsascript(
                title: "Manual backup failed",
                subtitle: repoName,
                body: errorMessage
            )
        }
    }

    static func postFailure(
        repoName: String,
        repoId: UUID,
        scheduleId: UUID,
        errorMessage: String,
        logPath: String
    ) {
        if isGUIProcess {
            let content = UNMutableNotificationContent()
            content.title = "Backup failed"
            content.subtitle = repoName
            content.body = errorMessage
            content.categoryIdentifier = failureCategoryId
            content.sound = .default
            content.userInfo = [
                userInfoRepoId: repoId.uuidString,
                userInfoScheduleId: scheduleId.uuidString,
                userInfoLogPath: logPath,
            ]
            deliverViaUN(content: content)
        } else {
            deliverViaOsascript(
                title: "Backup failed",
                subtitle: repoName,
                body: errorMessage
            )
        }
    }

    private static func deliverViaUN(content: UNNotificationContent) {
        registerCategories()
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        let sem = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    /// Headless-safe fallback: `osascript` can post notifications from any
    /// process that has been granted access under "Script Editor" (macOS
    /// permission is shared across apple-script-triggered notifications).
    /// Downsides: no action buttons, no custom categories. Good enough for
    /// the launchd path.
    private static func deliverViaOsascript(title: String, subtitle: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e",
            "display notification \(quote(body)) with title \(quote(title)) subtitle \(quote(subtitle))"
        ]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            fputs("osascript notification failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func quote(_ s: String) -> String {
        // AppleScript string literal: wrap in double quotes, escape embedded
        // double quotes and backslashes.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Delegate installed by the GUI (in AppDelegate) so tapping a backup
/// notification's action does the right thing — kickstart the launchd job
/// for "Reintentar" or open the log file for "Abrir log".
final class BorgMacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground delivery: show banner + sound even when BorgMac is the
        // frontmost app.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case Notifications.actionRetry:
            guard let repoIdString = info[Notifications.userInfoRepoId] as? String,
                  let repoId = UUID(uuidString: repoIdString),
                  let schedIdString = info[Notifications.userInfoScheduleId] as? String,
                  let scheduleId = UUID(uuidString: schedIdString) else { return }
            kickstart(repoId: repoId, scheduleId: scheduleId)

        case Notifications.actionOpenLog:
            guard let path = info[Notifications.userInfoLogPath] as? String else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        default:
            // Default tap: open the main window.
            if let window = NSApp.windows.first(where: { $0.title.hasPrefix("BorgMac") }) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func kickstart(repoId: UUID, scheduleId: UUID) {
        let label = ScheduleManager.label(repoId: repoId, scheduleId: scheduleId)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        try? p.run()
        // Don't waitUntilExit — UI callbacks should return fast.
    }
}
