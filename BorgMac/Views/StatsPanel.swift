import SwiftUI
import Charts

/// Point-in-time overview of every repo the app knows about, aggregated by
/// provider (local/Borg, BorgBase, BorgBox). No history yet — everything is
/// fetched fresh every time the panel opens.
struct StatsPanel: View {
    @EnvironmentObject var repoStore: RepositoryStore
    @EnvironmentObject var borgBoxStore: BorgBoxServerStore
    @EnvironmentObject var statusStore: BackupRunStatusStore
    @Environment(\.dismiss) private var dismiss

    @State private var loading = false
    @State private var error: String?

    /// Everything we gather and chart. Built fresh from all three sources on
    /// each `load()` call.
    @State private var entries: [StatsEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading && entries.isEmpty {
                        ProgressView("Loading statistics…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    summaryCard
                    byProviderCard
                    byRepoCard
                    ratiosCard
                    scheduledCard
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 740)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics").font(.title3.bold())
                Text("Point-in-time overview of your repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(loading)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Cards

    private var summaryCard: some View {
        GroupBox {
            HStack(spacing: 24) {
                metric("Repos", "\(entries.count)", systemImage: "externaldrive.fill")
                metric("Archives", "\(entries.reduce(0) { $0 + $1.archiveCount })", systemImage: "archivebox")
                metric("Total usage", formatBytes(Int64(entries.reduce(0) { $0 + $1.effectiveBytes })), systemImage: "chart.bar.fill")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ label: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var byProviderCard: some View {
        GroupBox("By provider") {
            Group {
                if entries.isEmpty {
                    Text("No data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let slices = providerSlices()
                    HStack(alignment: .center, spacing: 24) {
                        Chart(slices) { slice in
                            SectorMark(
                                angle: .value("Bytes", Double(slice.bytes)),
                                innerRadius: .ratio(0.55),
                                angularInset: 1
                            )
                            .foregroundStyle(by: .value("Provider", slice.provider.label))
                        }
                        .chartForegroundStyleScale(Self.providerColorScale)
                        .chartLegend(.hidden)
                        .frame(width: 220, height: 180)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(slices) { slice in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(slice.provider.tint)
                                        .frame(width: 10, height: 10)
                                    Text(slice.provider.label)
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    Text(formatBytes(slice.bytes))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var byRepoCard: some View {
        GroupBox("Size by repository") {
            Group {
                if entries.isEmpty {
                    Text("No data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let top = entries
                        .sorted { $0.effectiveBytes > $1.effectiveBytes }
                        .prefix(10)
                    Chart(top) { entry in
                        BarMark(
                            x: .value("Bytes", Double(entry.effectiveBytes)),
                            y: .value("Repo", entry.name)
                        )
                        .foregroundStyle(by: .value("Provider", entry.provider.label))
                    }
                    .chartForegroundStyleScale(Self.providerColorScale)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisValueLabel {
                                if let n = value.as(Double.self) {
                                    Text(formatBytes(Int64(n)))
                                        .font(.caption2)
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .frame(height: CGFloat(top.count) * 28 + 32)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ratiosCard: some View {
        GroupBox("Compression & deduplication (local repos)") {
            VStack(alignment: .leading, spacing: 6) {
                let locals = entries.filter { $0.provider == .local && $0.originalBytes > 0 }
                if locals.isEmpty {
                    Text("Only available for direct local/SSH repos. BorgBase and BorgBox repos don't expose detailed stats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(locals) { entry in
                        ratioRow(entry)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ratioRow(_ entry: StatsEntry) -> some View {
        let original = Double(entry.originalBytes)
        let compressed = Double(entry.compressedBytes)
        let deduped = Double(entry.effectiveBytes)
        let compRatio = original > 0 ? compressed / original : 0
        let dedupRatio = original > 0 ? deduped / original : 0
        return HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill").foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body.weight(.medium))
                HStack(spacing: 14) {
                    Text("orig \(formatBytes(entry.originalBytes))")
                    Text("comp \(formatBytes(entry.compressedBytes)) (\(percent(compRatio)))")
                    Text("dedup \(formatBytes(entry.effectiveBytes)) (\(percent(dedupRatio)))")
                        .foregroundStyle(.tint)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var scheduledCard: some View {
        GroupBox("Scheduled backups") {
            let (ok, running, failed, total) = scheduledAggregates()
            if total == 0 {
                Text("You don't have any scheduled backups configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 24) {
                    metric("Scheduled", "\(total)", systemImage: "clock.arrow.circlepath")
                    metric("Last OK", "\(ok)", systemImage: "checkmark.circle.fill")
                    metric("Running", "\(running)", systemImage: "arrow.triangle.2.circlepath")
                    metric("With error", "\(failed)", systemImage: "exclamationmark.triangle.fill")
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Data

    private func scheduledAggregates() -> (ok: Int, running: Int, failed: Int, total: Int) {
        var ok = 0, running = 0, failed = 0, total = 0
        for repo in repoStore.repositories {
            for schedule in repo.schedules {
                total += 1
                let status = statusStore.statuses[schedule.id]
                if status?.running == true {
                    running += 1
                } else if status?.lastError != nil {
                    failed += 1
                } else if status?.lastSuccess != nil {
                    ok += 1
                }
            }
        }
        return (ok, running, failed, total)
    }

    private func providerSlices() -> [ProviderSlice] {
        let grouped = Dictionary(grouping: entries, by: \.provider)
        return Provider.allCases.compactMap { provider in
            guard let items = grouped[provider], !items.isEmpty else { return nil }
            let bytes = items.reduce(Int64(0)) { $0 + $1.effectiveBytes }
            return ProviderSlice(provider: provider, bytes: bytes)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil

        // Gather each source into its own bucket first so we can dedupe
        // a single physical repo that's reachable through more than one
        // channel (e.g. a BorgBox repo the user also added as a local SSH
        // entry). The local entry wins because it carries the richer
        // orig/comp/dedup stats from `borg info`.
        var borgBaseRepos: [BorgBaseRepo] = []
        var borgBoxRepos: [(server: BorgBoxServer, repo: BorgBoxRemoteRepo)] = []
        var locals: [(repo: Repository, info: BorgRepoInfo, archives: Int)] = []

        if await BorgBaseClient.shared.hasToken() {
            do {
                borgBaseRepos = try await BorgBaseClient.shared.repos()
            } catch {
                print("[StatsPanel] BorgBase repos failed: \(error)")
            }
        }

        for server in borgBoxStore.servers {
            do {
                let repos = try await BorgBoxClient.shared.listRepos(server: server)
                for r in repos where r.isRegistered {
                    borgBoxRepos.append((server, r))
                }
            } catch {
                print("[StatsPanel] BorgBox listRepos failed: \(error)")
            }
        }

        // Local repos — `borg info --json` for the ratios, plus
        // `borg list --json` for a real archive count (info alone
        // returns an empty archives array). Serialised so we don't
        // spawn N borg processes at once.
        for local in repoStore.repositories {
            do {
                let info = try await BorgClient.shared.info(repo: local)
                let archives = (try? await BorgClient.shared.listArchives(repo: local).count) ?? 0
                locals.append((local, info, archives))
            } catch {
                print("[StatsPanel] borg info \(local.name) failed: \(error)")
            }
        }

        // Dedup pass: mark BorgBox / BorgBase remotes that are "claimed"
        // by a local entry so we don't emit them a second time. The
        // local entry inherits the remote's provider label so the pie
        // and bar chart credit it to the right hosting provider.
        var consumedBorgBox = Set<String>()
        var consumedBorgBase = Set<String>()

        var out: [StatsEntry] = []

        for (local, info, archives) in locals {
            var provider: Provider = .local
            if let match = borgBoxRepos.first(where: {
                Self.borgBoxMatches(server: $0.server, repo: $0.repo, localURL: local.url)
            }) {
                provider = .borgBox
                consumedBorgBox.insert("\(match.server.id)::\(match.repo.name)")
            } else if let match = borgBaseRepos.first(where: {
                Self.borgBaseMatches(repo: $0, localURL: local.url)
            }) {
                provider = .borgBase
                consumedBorgBase.insert(match.id)
            } else if Self.looksLikeBorgBaseURL(local.url) {
                // Fallback: no API match (usually because no token is saved,
                // so borgBaseRepos is empty), but the URL points at a
                // borgbase.com host — still classify it as BorgBase so the
                // pie chart doesn't miscredit it to Local/SSH.
                provider = .borgBase
            }
            out.append(StatsEntry(
                id: "local-\(local.id.uuidString)",
                name: local.name,
                provider: provider,
                originalBytes: info.cache.stats.totalSize,
                compressedBytes: info.cache.stats.totalCsize,
                effectiveBytes: info.cache.stats.uniqueCsize,
                archiveCount: archives
            ))
        }

        for (server, r) in borgBoxRepos where !consumedBorgBox.contains("\(server.id)::\(r.name)") {
            out.append(StatsEntry(
                id: "bx-\(server.id)-\(r.name)",
                name: r.name,
                provider: .borgBox,
                originalBytes: 0,
                compressedBytes: 0,
                effectiveBytes: r.sizeBytes ?? 0,
                archiveCount: 0
            ))
        }

        for r in borgBaseRepos where !consumedBorgBase.contains(r.id) {
            // BorgBase's GraphQL returns `currentUsage` in **megabytes**
            // (decimal, float). It's easy to mistake for GB because the
            // web dashboard shows "Current Usage: X GB", but the raw API
            // field is one scale lower. Multiplying by 10⁶ gives bytes.
            let used = Int64((r.currentUsage ?? 0) * 1_000_000)
            out.append(StatsEntry(
                id: "bb-\(r.id)",
                name: r.name,
                provider: .borgBase,
                originalBytes: 0,
                compressedBytes: 0,
                effectiveBytes: used,
                archiveCount: 0
            ))
        }

        entries = out
        publishWidgetSnapshot()
    }

    /// Writes the widget JSON snapshot using the numbers we just
    /// computed in `load()`. Doing it here rather than inside the
    /// writer avoids a second `borg info` sweep and keeps the widget
    /// and the stats panel trivially in sync.
    private func publishWidgetSnapshot() {
        let grouped = Dictionary(grouping: entries, by: \.provider)
        let byProvider: [WidgetSnapshot.ProviderUsage] = Provider.allCases.compactMap { provider in
            guard let items = grouped[provider], !items.isEmpty else { return nil }
            let bytes = items.reduce(Int64(0)) { $0 + $1.effectiveBytes }
            return WidgetSnapshot.ProviderUsage(
                providerKey: provider.rawValue,
                label: provider.label,
                bytes: bytes
            )
        }
        .sorted { $0.bytes > $1.bytes }

        // Top 5 by deduped size so the large widget shows the same
        // ranking as the "Size by repository" bar chart. Cap it here
        // (not in the writer) so the JSON stays small.
        let topRepos = entries
            .sorted { $0.effectiveBytes > $1.effectiveBytes }
            .prefix(5)
            .map { entry in
                WidgetSnapshot.RepoUsage(
                    name: entry.name,
                    providerKey: entry.provider.rawValue,
                    bytes: entry.effectiveBytes
                )
            }

        WidgetSnapshotWriter.write(
            repoCount: entries.count,
            archiveCount: entries.reduce(0) { $0 + $1.archiveCount },
            totalUsageBytes: entries.reduce(Int64(0)) { $0 + $1.effectiveBytes },
            byProvider: byProvider,
            topRepos: Array(topRepos),
            repoStore: repoStore,
            statusStore: statusStore
        )
    }

    /// Explicit label→colour mapping so the Chart series match the
    /// hand-rolled legend circles (`Provider.tint`). Without this, Swift
    /// Charts picks its own palette from `.foregroundStyle(by:)` and the
    /// two visuals drift out of sync.
    private static let providerColorScale: KeyValuePairs<String, Color> = [
        Provider.local.label:    Provider.local.tint,
        Provider.borgBase.label: Provider.borgBase.tint,
        Provider.borgBox.label:  Provider.borgBox.tint,
    ]

    // MARK: - Dedup helpers

    /// True when `localURL` points at the same physical repo as the
    /// given BorgBox remote. Prefers the daemon-reported `ssh_url`
    /// (v0.3.0+) and falls back to a URL built from the server's ssh
    /// fields + the repo's absolute path.
    private static func borgBoxMatches(
        server: BorgBoxServer,
        repo: BorgBoxRemoteRepo,
        localURL: String
    ) -> Bool {
        let canonLocal = canonicalizeSSHURL(localURL)
        if let sshUrl = repo.sshUrl, !sshUrl.isEmpty,
           canonicalizeSSHURL(sshUrl) == canonLocal {
            return true
        }
        let constructed = "ssh://\(server.sshUser)@\(server.sshHost):\(server.sshPort)\(repo.path)"
        return canonicalizeSSHURL(constructed) == canonLocal
    }

    /// BorgBase stores the exact `repoPath` returned by the API as the
    /// local `Repository.url` when the user creates a repo through the
    /// in-app wizard, so a direct canonical comparison catches it.
    private static func borgBaseMatches(repo: BorgBaseRepo, localURL: String) -> Bool {
        guard let path = repo.repoPath, !path.isEmpty else { return false }
        return canonicalizeSSHURL(path) == canonicalizeSSHURL(localURL)
    }

    /// True when the URL host belongs to the BorgBase SaaS. All BorgBase
    /// repos live under `*.repo.borgbase.com`, so a substring check on
    /// the lowercased URL is enough to recognise them without needing an
    /// API token.
    private static func looksLikeBorgBaseURL(_ url: String) -> Bool {
        url.lowercased().contains("borgbase.com")
    }

    /// Normalises an ssh://user@host:port/path URL for comparison:
    /// lowercases, trims a trailing slash, and drops an explicit `:22`
    /// so two URLs that differ only in whether the default port was
    /// spelled out still match.
    private static func canonicalizeSSHURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("/") { s.removeLast() }
        s = s.replacingOccurrences(of: ":22/", with: "/")
        if s.hasSuffix(":22") { s.removeLast(3) }
        return s
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }

    private func percent(_ r: Double) -> String {
        String(format: "%.0f%%", r * 100)
    }
}

// MARK: - Types

private enum Provider: String, CaseIterable, Hashable {
    case local, borgBase, borgBox

    var label: String {
        switch self {
        case .local:    return "Local/SSH"
        case .borgBase: return "BorgBase"
        case .borgBox:  return "BorgBox"
        }
    }

    var tint: Color {
        switch self {
        case .local:    return .blue
        case .borgBase: return .green
        case .borgBox:  return .yellow
        }
    }
}

private struct StatsEntry: Identifiable {
    let id: String
    let name: String
    let provider: Provider
    /// Total bytes across all archives before compression (only for local).
    let originalBytes: Int64
    /// Compressed bytes (only for local).
    let compressedBytes: Int64
    /// Bytes actually used on disk after dedup — for local it's
    /// `unique_csize` from `borg info`; for BorgBase the reported
    /// `currentUsage`; for BorgBox the server-computed `size_bytes`.
    let effectiveBytes: Int64
    let archiveCount: Int
}

private struct ProviderSlice: Identifiable {
    let provider: Provider
    let bytes: Int64
    var id: String { provider.rawValue }
}
