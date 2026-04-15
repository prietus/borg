import AppKit
import UserNotifications

/// Hybrid activation policy: the app starts as a menu-bar accessory (no Dock
/// icon, no cmd-tab presence), but the moment a real user-facing window
/// appears we switch to `.regular` so the user can find it in the Dock,
/// cmd-tab, Mission Control, etc. When the last user window closes we go
/// back to `.accessory`.
///
/// "User window" detection is whitelist-based on the window title — system
/// windows like the Touch ID authentication panel, NSSavePanels, color
/// pickers, etc. must NOT trigger policy changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Title prefixes that identify our own user-facing windows.
    /// Compared with `hasPrefix` so that subtitles appended by SwiftUI
    /// (e.g. " — repo name") still match.
    private static let userWindowTitlePrefixes = [
        "BorgMac",
        "New on BorgBase",
        "New on BorgBox",
        "New Borg Repository",
    ]

    /// Pending switch to `.accessory`, debounced so transient window
    /// transitions (like the Touch ID prompt dismissing) don't flicker
    /// the policy.
    private var pendingAccessorySwitch: DispatchWorkItem?

    /// Strong reference required — `UNUserNotificationCenter.delegate` is
    /// held weakly, so we own the lifetime from here.
    private let notificationDelegate = BorgMacNotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().delegate = notificationDelegate
        Notifications.bootstrap()

        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              Self.isUserWindow(window) else { return }

        // Cancel any pending switch back to accessory: a user window is
        // active again.
        pendingAccessorySwitch?.cancel()
        pendingAccessorySwitch = nil

        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              Self.isUserWindow(window) else {
            // Ignore close notifications from system windows (Touch ID,
            // save panels, the menu bar popover, etc.)
            return
        }

        // Debounce: if another user window becomes key shortly after, the
        // pending work is cancelled.
        pendingAccessorySwitch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            let stillOpen = NSApp.windows.contains { window in
                window.isVisible && Self.isUserWindow(window)
            }
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        pendingAccessorySwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func isUserWindow(_ window: NSWindow) -> Bool {
        let title = window.title
        guard !title.isEmpty else { return false }
        for prefix in userWindowTitlePrefixes where title.hasPrefix(prefix) {
            return true
        }
        return false
    }
}
