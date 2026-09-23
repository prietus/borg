import SwiftUI

struct BorgBaseSheet: View {
    var onImport: (_ name: String, _ url: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput: String = ""
    @State private var hasToken: Bool = false
    @State private var repos: [BorgBaseRepo] = []
    @State private var sshKeys: [BorgBaseSSHKey] = []
    @State private var loading = false
    @State private var error: String?
    @State private var section: Section = .repos
    @State private var pendingDeleteRepo: BorgBaseRepo?
    @State private var pendingDeleteKey: BorgBaseSSHKey?
    @State private var editingRepo: BorgBaseRepo?
    @State private var pendingCompactRepo: BorgBaseRepo?
    @State private var infoBanner: String?

    /// Tracks repos that have a server-side compaction in flight. BorgBase
    /// exposes no progress stream, so we keep this in-memory (per-session)
    /// and clear entries either when `currentUsage` drops below the value at
    /// trigger time, or after a 60-minute safety timeout.
    @State private var compactingSince: [String: CompactEntry] = [:]

    private struct CompactEntry {
        let triggeredAt: Date
        let usageAtTriggerMB: Double
    }

    enum Section: String, CaseIterable, Identifiable {
        case repos = "Repositories"
        case keys = "SSH Keys"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if hasToken {
                sectionPicker
                Divider()
                content
            } else {
                tokenEntry
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 560)
        .task {
            if await BorgBaseClient.shared.hasToken() {
                hasToken = true
                await reload()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
        .confirmationDialog(
            "Delete repo \(pendingDeleteRepo?.name ?? "")?",
            isPresented: Binding(
                get: { pendingDeleteRepo != nil },
                set: { if !$0 { pendingDeleteRepo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                if let repo = pendingDeleteRepo {
                    deleteRepo(repo)
                }
                pendingDeleteRepo = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteRepo = nil }
        } message: {
            Text("This deletes the repository and all its archives on BorgBase. It cannot be undone.")
        }
        .sheet(item: $editingRepo) { repo in
            BorgBaseEditRepoSheet(repo: repo, accountKeys: sshKeys) {
                Task { await reload() }
            }
        }
        .confirmationDialog(
            "Delete key \(pendingDeleteKey?.name ?? "")?",
            isPresented: Binding(
                get: { pendingDeleteKey != nil },
                set: { if !$0 { pendingDeleteKey = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let key = pendingDeleteKey {
                    deleteKey(key)
                }
                pendingDeleteKey = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteKey = nil }
        } message: {
            Text("Repos whose only access was this key will no longer be reachable.")
        }
        .confirmationDialog(
            "Compact \(pendingCompactRepo?.name ?? "")?",
            isPresented: Binding(
                get: { pendingCompactRepo != nil },
                set: { if !$0 { pendingCompactRepo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Compact now") {
                if let repo = pendingCompactRepo {
                    compactRepo(repo)
                }
                pendingCompactRepo = nil
            }
            Button("Cancel", role: .cancel) { pendingCompactRepo = nil }
        } message: {
            Text("Runs `borg compact` on BorgBase's side to reclaim space freed by pruned archives. The repo stays usable but writes may be slower while it runs.")
        }
        .alert(
            "BorgBase",
            isPresented: Binding(
                get: { infoBanner != nil },
                set: { if !$0 { infoBanner = nil } }
            ),
            actions: { Button("OK") { infoBanner = nil } },
            message: { Text(infoBanner ?? "") }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("BorgBase").font(.title3.bold())
                Text("Remote panel: repositories and SSH keys from your account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            }
            if hasToken {
                Button("Disconnect") {
                    Task {
                        await BorgBaseClient.shared.clearToken()
                        Keychain.deleteBorgBaseToken()
                        hasToken = false
                        repos = []
                        sshKeys = []
                        tokenInput = ""
                    }
                }
                .buttonStyle(.bordered)
                .help("Remove the BorgBase API token from this Mac")
            }
        }
        .padding(14)
    }

    // MARK: - Token entry

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your BorgBase API token")
                .font(.headline)
            Text("You can generate one at https://www.borgbase.com/settings/access_tokens with read scope to list repos and keys. It is stored in the local Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Token", text: $tokenInput, prompt: Text("Paste your token here"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Save and connect") {
                    saveToken()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Section picker

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .repos: reposView
        case .keys:  keysView
        }
    }

    private var reposView: some View {
        Group {
            if repos.isEmpty {
                ContentUnavailableView(
                    loading ? "Loading…" : "No repositories",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(
                        loading ? "Querying BorgBase…" : "Your account has no repositories or the token lacks permissions."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    aggregateStrip
                    Divider()
                    List(repos) { repo in
                        repoRow(repo)
                            .padding(.vertical, 4)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
    }

    // Compact summary strip above the repo list. Uses only data we already
    // fetch (currentUsage, quota, alertDays, lastModified), so it adds no
    // new queries.
    private var aggregateStrip: some View {
        let totalUsed = repos.reduce(0.0) { $0 + ($1.currentUsage ?? 0) }
        let nearQuota = repos.filter { repo in
            guard repo.quotaEnabled == true,
                  let q = repo.quota, q > 0,
                  let used = repo.currentUsage else { return false }
            return (used / q) > 0.75
        }.count
        let staleCount = repos.filter(\.isStale).count
        return HStack(spacing: 14) {
            aggregateItem(
                icon: "externaldrive.fill",
                value: "\(repos.count)",
                label: repos.count == 1 ? "repo" : "repos"
            )
            aggregateItem(
                icon: "chart.bar.fill",
                value: formatMB(totalUsed),
                label: "used"
            )
            if nearQuota > 0 {
                aggregateItem(
                    icon: "exclamationmark.triangle.fill",
                    value: "\(nearQuota)",
                    label: nearQuota == 1 ? "near quota" : "near quota",
                    tint: .orange
                )
            }
            if staleCount > 0 {
                aggregateItem(
                    icon: "clock.badge.exclamationmark",
                    value: "\(staleCount)",
                    label: staleCount == 1 ? "stale" : "stale",
                    tint: .orange
                )
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func aggregateItem(
        icon: String,
        value: String,
        label: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint == .secondary ? .primary : tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Formats a MB value (as returned by BorgBase's GraphQL) as a human-
    /// readable string. Uses decimal units (1000-based) to match how BorgBase
    /// itself reports sizes on its web dashboard.
    private func formatMB(_ mb: Double) -> String {
        let bytes = Int64(mb * 1_000_000)
        let fmt = ByteCountFormatter()
        fmt.countStyle = .decimal
        fmt.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        fmt.includesUnit = true
        return fmt.string(fromByteCount: bytes)
    }

    /// Formats the repo's `lastModified` as a relative string ("2 days ago",
    /// "just now"). Returns nil when BorgBase didn't provide a parseable date
    /// — typically brand-new repos that have never received a backup.
    private func lastActivityLabel(_ repo: BorgBaseRepo) -> String? {
        guard let date = repo.lastModifiedDate else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func repoRow(_ repo: BorgBaseRepo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.name).font(.headline)
                if let path = repo.repoPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                quotaBar(repo)
                HStack(spacing: 12) {
                    if let region = repo.region {
                        Label(region, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let encryption = repo.encryption, !encryption.isEmpty {
                        Label(encryption, systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let activity = lastActivityLabel(repo) {
                        Label(activity, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(repo.isStale ? .orange : .secondary)
                            .help(repo.isStale
                                  ? "This repo hasn't been modified within its alert window (\(repo.alertDays ?? 0) days)."
                                  : "Last activity reported by BorgBase.")
                    }
                    if repo.isStale {
                        Text("Stale")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                guard let path = repo.repoPath, !path.isEmpty else { return }
                onImport(repo.name, path)
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(repo.repoPath?.isEmpty ?? true || repoAlreadyImported(repo))
            .help(importHelp(for: repo))
            if let entry = compactingSince[repo.id] {
                compactingPill(since: entry.triggeredAt)
            }
            Menu {
                Button {
                    editingRepo = repo
                } label: {
                    Label("Edit…", systemImage: "slider.horizontal.3")
                }
                Button {
                    pendingCompactRepo = repo
                } label: {
                    Label("Compact on BorgBase…", systemImage: "archivebox")
                }
                .disabled(compactingSince[repo.id] != nil)
                Divider()
                Button(role: .destructive) {
                    pendingDeleteRepo = repo
                } label: {
                    Label("Delete repo…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More actions")
        }
    }

    private func quotaBar(_ repo: BorgBaseRepo) -> some View {
        // BorgBase's `currentUsage` and `quota` are reported in **megabytes**
        // (decimal MB, float). The web dashboard does the unit conversion for
        // display; raw API values look GB-sized but are ~1000× smaller.
        let usedMB = repo.currentUsage ?? 0
        let quotaMB = repo.quota ?? 0
        let hasQuota = repo.quotaEnabled == true && quotaMB > 0
        let usedText = formatMB(usedMB)
        let totalText = hasQuota ? formatMB(quotaMB) : "∞"
        let ratio: Double = hasQuota ? min(usedMB / quotaMB, 1.0) : 0.0
        let tint: Color = ratio > 0.9 ? .red : (ratio > 0.75 ? .orange : .accentColor)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(usedText) / \(totalText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ratio > 0.85 ? tint : .secondary)
                if hasQuota {
                    Text(String(format: "· %.0f%%", ratio * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if hasQuota {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(maxWidth: 260)
            }
        }
    }

    private var keysView: some View {
        Group {
            if sshKeys.isEmpty {
                ContentUnavailableView(
                    loading ? "Loading…" : "No SSH keys",
                    systemImage: "key",
                    description: Text(
                        loading ? "Querying BorgBase…" : "No keys registered in your account."
                    )
                )
            } else {
                List(sshKeys) { key in
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name).font(.headline)
                            HStack(spacing: 10) {
                                if let type = key.keyType {
                                    Text(type).font(.caption).foregroundStyle(.secondary)
                                }
                                if let bits = key.bits {
                                    Text("\(bits) bits").font(.caption).foregroundStyle(.secondary)
                                }
                                if let hash = key.hashMd5 {
                                    Text(hash)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDeleteKey = key
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete SSH key from BorgBase")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if hasToken {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: - Actions

    @EnvironmentObject private var store: RepositoryStore

    private func repoAlreadyImported(_ repo: BorgBaseRepo) -> Bool {
        guard let path = repo.repoPath else { return false }
        return store.repositories.contains { $0.url == path }
    }

    private func importHelp(for repo: BorgBaseRepo) -> String {
        if repoAlreadyImported(repo) {
            return "This repository is already added locally."
        }
        return "Prefill a new local repository with this URL."
    }

    private func saveToken() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.setBorgBaseToken(trimmed)
            Task {
                await BorgBaseClient.shared.setToken(trimmed)
                hasToken = true
                await reload()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func compactRepo(_ repo: BorgBaseRepo) {
        Task {
            do {
                try await BorgBaseClient.shared.compactRepo(id: repo.id)
                compactingSince[repo.id] = CompactEntry(
                    triggeredAt: Date(),
                    usageAtTriggerMB: repo.currentUsage ?? 0
                )
                infoBanner = "Compaction started on BorgBase for “\(repo.name)”. It runs in the background — usage should drop over the next minutes."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Amber pill shown next to a repo while we believe BorgBase is still
    /// compacting it. Uses a periodic TimelineView so the "Nm ago" text
    /// updates without us managing a Timer.
    @ViewBuilder
    private func compactingPill(since: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(.caption2)
                Text("Compacting · \(relativeAgo(since, now: context.date))")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help("BorgBase is compacting this repo in the background. The pill disappears when usage drops or after 60 minutes.")
        }
    }

    private func relativeAgo(_ date: Date, now: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: now)
    }

    /// Drops compaction entries that either (a) completed — detected by a
    /// usage drop vs the value at trigger time — or (b) hit the 60-minute
    /// safety timeout so a stuck request doesn't linger forever.
    private func pruneCompactEntries(against fresh: [BorgBaseRepo]) {
        guard !compactingSince.isEmpty else { return }
        let now = Date()
        let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        compactingSince = compactingSince.filter { id, entry in
            if now.timeIntervalSince(entry.triggeredAt) > 3600 { return false }
            if let repo = byId[id],
               let newUsage = repo.currentUsage,
               newUsage < entry.usageAtTriggerMB {
                return false
            }
            return true
        }
    }

    private func deleteRepo(_ repo: BorgBaseRepo) {
        Task {
            do {
                try await BorgBaseClient.shared.deleteRepo(id: repo.id)
                removeLocalCounterpart(repo)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Removes any local `Repository` whose URL matches the just-deleted
    /// BorgBase repo's path, so the main sidebar doesn't keep a dangling
    /// entry whose upstream no longer exists.
    private func removeLocalCounterpart(_ repo: BorgBaseRepo) {
        guard let path = repo.repoPath, !path.isEmpty else { return }
        let matches = store.repositories.filter { $0.url == path }
        for local in matches {
            store.remove(local)
        }
    }

    private func deleteKey(_ key: BorgBaseSSHKey) {
        Task {
            do {
                try await BorgBaseClient.shared.deleteSSHKey(id: key.id)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            async let reposTask = BorgBaseClient.shared.repos()
            async let keysTask  = BorgBaseClient.shared.sshKeys()
            let (repos, keys) = try await (reposTask, keysTask)
            self.repos = repos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.sshKeys = keys.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            pruneCompactEntries(against: repos)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
