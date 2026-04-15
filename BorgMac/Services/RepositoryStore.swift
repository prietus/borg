import Foundation

@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []

    /// Set by callers (e.g. menu bar) to request that ContentView focus a
    /// particular repository. ContentView observes this and clears it after
    /// applying the selection.
    @Published var pendingSelection: UUID?

    private let fileURL: URL

    private static let migrationFlagKey = "com.carlos.BorgMac.migratedMultiJobSchedules.v1"

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BorgMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("repositories.json")
        load()
        migrateLegacySchedulesIfNeeded()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let repos = try? JSONDecoder().decode([Repository].self, from: data) else {
            return
        }
        repositories = repos
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(repositories) else { return }
        try? data.write(to: fileURL)
    }

    // MARK: - Mutations

    func add(_ repo: Repository, passphrase: String) throws {
        try Keychain.setPassphrase(passphrase, for: repo.id)
        repositories.append(repo)
        persist()
    }

    /// Adds a repository whose passphrase is already known but should not be
    /// re-stored (e.g. because we just initialized it and the wizard already
    /// stored the passphrase explicitly).
    func addWithoutPassphrase(_ repo: Repository) {
        repositories.append(repo)
        persist()
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        Keychain.delete(repoId: repo.id)
        ScheduleManager.uninstallAll(repoId: repo.id)
        for schedule in repo.schedules {
            BackupStatusFile.delete(for: schedule.id)
        }
        persist()
    }

    /// Replace an existing repository with updated fields (used when the
    /// user toggles or edits a schedule). No keychain side effects.
    func update(_ repo: Repository) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[idx] = repo
        persist()
    }

    // MARK: - Migration

    /// One-shot migration from the pre-multi-job layout:
    /// - old plist `com.carlos.BorgMac.backup.<repoUUID>.plist` → remove.
    /// - old status file `status/<repoUUID>.json` → remove.
    /// - reinstall every current schedule under the new label format.
    ///
    /// Idempotent after the UserDefaults flag is set.
    private func migrateLegacySchedulesIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.migrationFlagKey) == false else { return }

        for repo in repositories {
            // Drop the legacy single-schedule plist if it's still installed.
            ScheduleManager.uninstallLegacy(repoId: repo.id)

            // Drop the legacy status file (it was keyed by repoId).
            BackupStatusFile.delete(for: repo.id)

            // Reinstall every schedule that actually lives on this repo so
            // the launchd side has the right label format.
            for schedule in repo.schedules {
                try? ScheduleManager.install(repoId: repo.id, schedule: schedule)
            }
        }

        // Persist in case any schedule ids were freshly generated during the
        // legacy-decoder fallback.
        persist()
        defaults.set(true, forKey: Self.migrationFlagKey)
    }
}
