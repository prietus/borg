import SwiftUI

struct BorgMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()
    @StateObject private var borgBoxStore = BorgBoxServerStore()
    @StateObject private var statusStore = BackupRunStatusStore()
    @StateObject private var manualBackupStore = ManualBackupStore()

    var body: some Scene {
        // `Window` (not `WindowGroup`) so the main window is a singleton:
        // subsequent `openWindow(id: "main")` calls focus the existing
        // instance instead of spawning duplicates. The title "BorgMac" keeps
        // AppDelegate's user-window whitelist (prefix match) working.
        Window("BorgMac", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(borgBoxStore)
                .environmentObject(statusStore)
                .environmentObject(manualBackupStore)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("New on BorgBase", id: "wizard") {
            BorgBaseQuickSetupSheet()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("New Borg Repository", id: "borg-wizard") {
            BorgQuickSetupSheet()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("New on BorgBox", id: "borgbox-wizard") {
            BorgBoxQuickSetupSheet()
                .environmentObject(store)
                .environmentObject(borgBoxStore)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("BorgMac", systemImage: "shippingbox.fill") {
            MenuBarContentView()
                .environmentObject(store)
                .environmentObject(statusStore)
                .environmentObject(manualBackupStore)
        }
        .menuBarExtraStyle(.window)
    }
}
