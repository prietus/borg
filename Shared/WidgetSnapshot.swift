import Foundation

/// JSON payload the host app writes to disk for the WidgetKit extension
/// to read. Both targets (`BorgMac` and `BorgMacWidget`) compile this
/// file. Path: `~/Library/Application Support/BorgMac/widget-snapshot.json`.
///
/// The widget is sandboxed-off (matches the host) so it can read the
/// path directly without an App Group — this avoids registering a group
/// identifier with the developer portal and keeps ad-hoc dev builds
/// working. If we ever move to App Store distribution, we'd switch to a
/// `group.com.carlos.BorgMac` container.
struct WidgetSnapshot: Codable, Equatable {
    /// When the host app generated this snapshot. Widgets display it as
    /// "hace Xm" so the user can tell if data is stale (e.g. app hasn't
    /// been opened in days).
    let generatedAt: Date

    /// Count of repositories known to the app at snapshot time. Shown as
    /// the "N repos" chip.
    let repoCount: Int

    /// Total archives across every local repo. BorgBox and BorgBase
    /// don't expose per-repo archive counts cheaply so they contribute
    /// zero — the number matches what the Stats panel shows.
    let archiveCount: Int

    /// Sum of `effectiveBytes` across every repo. This is deduped usage
    /// where available (local) and reported usage otherwise (BorgBox /
    /// BorgBase), so it matches the "Total usage" figure in StatsPanel.
    let totalUsageBytes: Int64

    /// One entry per provider that actually has data. Ordered so the
    /// largest slice comes first — the widget view takes a `prefix(3)`
    /// to keep the layout compact.
    let byProvider: [ProviderUsage]

    /// Per-repo usage, sorted by bytes descending. Capped at a handful
    /// of entries when written so the JSON stays small. The large
    /// widget renders mini-bars; the medium widget ignores this and
    /// shows only `byProvider`.
    let topRepos: [RepoUsage]

    /// Next schedule that will fire, across every repo and every
    /// schedule. `nil` when there are no enabled schedules.
    let nextBackup: NextBackup?

    /// Overall health indicator. Green when every schedule's last run
    /// succeeded (or hasn't run yet). Warning when a run is currently
    /// in progress. Error when at least one schedule reports a failure.
    let health: Health

    struct ProviderUsage: Codable, Equatable, Identifiable {
        /// Stable key — "local", "borgBase", "borgBox" — matches the
        /// `Provider` enum raw values in StatsPanel. The widget maps
        /// this to the same colors to keep both surfaces in sync.
        let providerKey: String
        /// Human label shown next to the bar ("Local/SSH", "BorgBase",
        /// "BorgBox").
        let label: String
        let bytes: Int64

        var id: String { providerKey }
    }

    struct RepoUsage: Codable, Equatable, Identifiable {
        let name: String
        /// Same key space as `ProviderUsage.providerKey` so the widget
        /// can tint the mini-bar with the provider colour.
        let providerKey: String
        let bytes: Int64

        var id: String { "\(providerKey)::\(name)" }
    }

    struct NextBackup: Codable, Equatable {
        let repoName: String
        let scheduleName: String
        let fireDate: Date
    }

    enum Health: String, Codable {
        case ok
        case running
        case error
    }

    /// Canonical on-disk path under Application Support. The host app
    /// is non-sandboxed so it writes here freely. The widget extension
    /// is sandboxed (PlugInKit requires it) and gets read access to
    /// exactly this one file via a
    /// `temporary-exception.files.home-relative-path.read-only`
    /// entitlement — no App Group, no team ID validation, so dev
    /// builds signed `-` still work.
    ///
    /// Note: inside a sandbox, `FileManager.applicationSupportDirectory`
    /// resolves to the sandbox container (e.g.
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support`),
    /// not the user's real home. The widget would end up reading an
    /// empty path. `getpwuid(getuid()).pw_dir` is the documented
    /// escape hatch: it returns the actual home directory regardless
    /// of sandbox, and is exactly what the `home-relative-path`
    /// exception is anchored to.
    static var fileURL: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent("Library/Application Support/BorgMac", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    /// Reads the snapshot from disk. Returns nil when the file is
    /// missing or can't be decoded — the widget falls back to a
    /// "unavailable" placeholder in that case.
    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Writes atomically via a temp file + rename so a concurrent
    /// widget read never sees a half-written payload.
    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
