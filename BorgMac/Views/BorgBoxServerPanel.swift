import SwiftUI

struct BorgBoxServerPanel: View {
    @EnvironmentObject var serverStore: BorgBoxServerStore
    @EnvironmentObject var repoStore: RepositoryStore
    @EnvironmentObject var license: LicenseManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var jobsStore = BorgBoxJobsStore()

    @State private var stats: BorgBoxSystemStats?
    @State private var repos: [BorgBoxRemoteRepo] = []
    @State private var sessions: [BorgBoxSession] = []
    @State private var loading = false
    @State private var error: String?

    /// Sub-sheet state — only one of these can be presented at a time.
    @State private var pruneTarget: PruneTarget?
    @State private var archivesTarget: ArchivesTarget?
    @State private var importTarget: BorgBoxRemoteRepo?
    @State private var registerTarget: BorgBoxRemoteRepo?
    @State private var passphrasePrompt: PassphrasePrompt?
    @State private var pendingDeleteRepo: String?
    @State private var pendingChangeServer: Bool = false

    // Inline "add server" form state — used when no server is configured
    // and the panel offers to set one up without going to the wizard.
    @State private var newServerName: String = "My BorgBox server"
    @State private var newServerURL: String = "http://hive.local:9999"
    @State private var newServerToken: String = ""
    @State private var newServerSSHUser: String = "borg"
    @State private var newServerSSHPort: String = "22"
    @State private var newServerSSHHost: String = ""
    @State private var newServerShowAdvanced: Bool = false
    @State private var validatingServer: Bool = false

    /// Passphrases the user entered during this panel session, keyed by
    /// remote repo name. Only kept in-memory — wiped when the sheet closes.
    @State private var sessionPassphrases: [String: String] = [:]

    /// Jobs whose log tail the user has expanded to see the full rolling
    /// buffer. Collapsed by default.
    @State private var expandedJobLogs: Set<String> = []

    private struct PruneTarget: Identifiable {
        let id = UUID()
        let repo: String
        let passphrase: String?
    }

    private struct ArchivesTarget: Identifiable {
        let id = UUID()
        let repo: String
        let passphrase: String?
    }

    private struct PassphrasePrompt: Identifiable {
        let id = UUID()
        let repoName: String
        let action: String
        let then: (String) -> Void
    }

    var body: some View {
        Group {
            if let server = serverStore.first {
                content(server: server)
            } else {
                serverEntryForm
            }
        }
        .frame(width: 680, height: 720)
    }

    @ViewBuilder
    private func content(server: BorgBoxServer) -> some View {
        VStack(spacing: 0) {
            header(server: server)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading && stats == nil {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    if let stats {
                        statsCard(stats)
                    }
                    sessionsCard
                    reposCard(server: server)
                    jobsCard(server: server)
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(20)
            }
        }
        .task(id: server.id) { await loadAll(server: server) }
        .sheet(item: $pruneTarget) { target in
            BorgBoxPruneSheet(
                server: server,
                repo: target.repo,
                passphrase: target.passphrase
            ) { start in
                jobsStore.register(initial: start, kind: "prune", repo: target.repo, server: server)
            }
        }
        .sheet(item: $archivesTarget) { target in
            BorgBoxArchivesSheet(
                server: server,
                repo: target.repo,
                passphrase: target.passphrase
            )
        }
        .sheet(item: $importTarget) { remote in
            BorgBoxImportSheet(
                server: server,
                remoteName: remote.name,
                remotePath: remote.path,
                remoteSSHUrl: remote.sshUrl,
                mode: .existingKey
            )
            .environmentObject(repoStore)
        }
        .sheet(item: $registerTarget) { remote in
            BorgBoxImportSheet(
                server: server,
                remoteName: remote.name,
                remotePath: remote.path,
                remoteSSHUrl: remote.sshUrl,
                mode: .register
            )
            .environmentObject(repoStore)
            .onDisappear {
                // After a successful register the daemon's /repos list will
                // show the repo as `registered: true`; refresh to reflect.
                Task { await loadAll(server: server) }
            }
        }
        .sheet(item: $passphrasePrompt) { prompt in
            BorgBoxPassphraseSheet(
                repoName: prompt.repoName,
                action: prompt.action
            ) { entered in
                sessionPassphrases[prompt.repoName] = entered
                // Persist so the next submenu / next app launch doesn't ask
                // again. The user can clear it via `deleteBorgBoxRepoPassphrase`
                // if the repo passphrase ever changes.
                try? Keychain.setBorgBoxRepoPassphrase(
                    entered,
                    serverId: server.id,
                    repo: prompt.repoName
                )
                prompt.then(entered)
            }
        }
        .confirmationDialog(
            "Delete repo \(pendingDeleteRepo ?? "")?",
            isPresented: Binding(
                get: { pendingDeleteRepo != nil },
                set: { if !$0 { pendingDeleteRepo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete from server", role: .destructive) {
                if let name = pendingDeleteRepo {
                    runDelete(repo: name, server: server)
                }
                pendingDeleteRepo = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteRepo = nil }
        } message: {
            Text("This deletes the repo from the BorgBox daemon. The on-disk data is lost and cannot be recovered.")
        }
        .confirmationDialog(
            "Forget this BorgBox server?",
            isPresented: $pendingChangeServer,
            titleVisibility: .visible
        ) {
            Button("Forget server", role: .destructive) {
                serverStore.remove(server)
                pendingChangeServer = false
            }
            Button("Cancel", role: .cancel) { pendingChangeServer = false }
        } message: {
            Text("Existing repos stay in your sidebar but keep pointing at this server's SSH host. If the next server is a different machine, their scheduled backups will fail until you reconfigure them.")
        }
    }

    // MARK: - Header

    private func header(server: BorgBoxServer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.title3.bold())
                Text(server.daemonURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await loadAll(server: server) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(loading)

            Menu {
                Button("Change server…", role: .destructive) {
                    pendingChangeServer = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Stats card

    private func statsCard(_ stats: BorgBoxSystemStats) -> some View {
        GroupBox("Server") {
            VStack(alignment: .leading, spacing: 8) {
                row("Hostname", stats.hostname)
                row("Uptime", formatUptime(seconds: stats.uptimeSeconds))
                row("Load", stats.load.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                if let v = stats.borgboxVersion {
                    row("Daemon version", v)
                }
                Divider()
                row("Path", stats.storage.path)
                row("Total", formatBytes(stats.storage.totalBytes))
                row("Used", formatBytes(stats.storage.usedBytes))
                row("Free", formatBytes(stats.storage.freeBytes))
                ProgressView(
                    value: Double(stats.storage.usedBytes),
                    total: Double(max(stats.storage.totalBytes, 1))
                )
                .tint(storageTint(stats.storage))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func storageTint(_ storage: BorgBoxSystemStats.Storage) -> Color {
        let pct = Double(storage.usedBytes) / Double(max(storage.totalBytes, 1))
        if pct > 0.9 { return .red }
        if pct > 0.75 { return .orange }
        return .accentColor
    }

    // MARK: - Sessions card

    private var sessionsCard: some View {
        GroupBox("Active sessions") {
            VStack(alignment: .leading, spacing: 6) {
                if sessions.isEmpty {
                    Text("No active borg sessions at the moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.fill")
                            .foregroundStyle(.tint)
                        Text(session.repo).font(.body.monospaced())
                        Spacer()
                        if let ip = session.clientIp {
                            Text(ip)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let cpu = session.cpuPercent {
                            Text(String(format: "%.0f%%", cpu))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Repos card

    private func reposCard(server: BorgBoxServer) -> some View {
        GroupBox("Repositories") {
            VStack(alignment: .leading, spacing: 6) {
                if repos.isEmpty {
                    Text("No repositories registered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(repos) { repo in
                        repoRow(repo, server: server)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repoRow(_ repo: BorgBoxRemoteRepo, server: BorgBoxServer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: repo.isRegistered ? "externaldrive.fill" : "externaldrive.badge.questionmark")
                .foregroundStyle(repo.isRegistered ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.body.weight(.medium))
                    if !repo.isRegistered {
                        Text("Unregistered")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if let size = repo.sizeBytes {
                    Text(formatBytes(size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if repo.isRegistered {
                Menu {
                    Button("Archives…") { startArchives(repo: repo.name, server: server) }
                    Divider()
                    Button("Check") { startCheck(repo: repo.name, server: server) }
                    Button("Prune…") { startPrune(repo: repo.name, server: server) }
                    Button("Compact") { startCompact(repo: repo.name, server: server) }
                    Divider()
                    if !isAlreadyImported(repo) {
                        Button("Import into BorgMac…") { importTarget = repo }
                            .disabled(!license.status.canCreateNew)
                    }
                    Button("Break lock", role: .destructive) {
                        runBreakLock(repo: repo.name, server: server)
                    }
                    Button("Delete repo…", role: .destructive) {
                        pendingDeleteRepo = repo.name
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button {
                    registerTarget = repo
                } label: {
                    Label("Register…", systemImage: "key.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!license.status.canCreateNew)
                .help(license.status.canCreateNew
                      ? "Generates a dedicated SSH key, registers it with the daemon, and adopts the repo in BorgMac."
                      : "Trial expired — buy a license to register a new repository.")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Jobs card

    private func jobsCard(server: BorgBoxServer) -> some View {
        GroupBox("Operations") {
            VStack(alignment: .leading, spacing: 10) {
                if jobsStore.orderedJobs.isEmpty {
                    Text("No operations. Launch Check/Prune/Compact from a repo's ⋯ menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(jobsStore.orderedJobs) { job in
                    jobRow(job)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func jobRow(_ job: BorgBoxJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            jobStatusIcon(job)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(job.kind) · \(job.repo ?? "?")")
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(job.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        jobsStore.dismiss(jobId: job.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                jobLogTail(job)
            }
        }
    }

    @ViewBuilder
    private func jobLogTail(_ job: BorgBoxJob) -> some View {
        // Prefer the live buffer (SSE) — it's what we've been appending in
        // real time. Fall back to the snapshot `log_tail` for terminal jobs
        // rehydrated from `GET /jobs`.
        let live = jobsStore.logs[job.id] ?? []
        let lines = !live.isEmpty ? live : (job.logTail ?? [])
        if !lines.isEmpty {
            let isExpanded = expandedJobLogs.contains(job.id)
            let hasMore = lines.count > 6

            VStack(alignment: .leading, spacing: 4) {
                if isExpanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(lines.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(6)
                                .id("log-bottom-\(job.id)-\(lines.count)")
                        }
                        .frame(maxHeight: 220)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2))
                        )
                        .onAppear {
                            proxy.scrollTo("log-bottom-\(job.id)-\(lines.count)", anchor: .bottom)
                        }
                        .onChange(of: lines.count) { _, _ in
                            proxy.scrollTo("log-bottom-\(job.id)-\(lines.count)", anchor: .bottom)
                        }
                    }
                } else {
                    let recent = Array(lines.suffix(6))
                    Text(recent.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(6)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }

                if hasMore || isExpanded {
                    Button {
                        if isExpanded {
                            expandedJobLogs.remove(job.id)
                        } else {
                            expandedJobLogs.insert(job.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                            Text(isExpanded
                                 ? "Collapse"
                                 : "Show full log (\(lines.count) lines)")
                                .font(.caption)
                        }
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func jobStatusIcon(_ job: BorgBoxJob) -> some View {
        if job.isTerminal {
            if job.isFailure {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Helpers

    // MARK: - Server entry (when no server is configured)

    private var serverEntryForm: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure your BorgBox server").font(.title3.bold())
                    Text("Paste the daemon URL and API token. We check /health and /info before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Server") {
                    TextField("Name", text: $newServerName, prompt: Text("e.g. Home NAS"))
                    TextField("Daemon URL", text: $newServerURL,
                              prompt: Text("http://host:9999"))
                        .autocorrectionDisabled()
                    SecureField("API token", text: $newServerToken)
                }

                Section {
                    DisclosureGroup("SSH (advanced)", isExpanded: $newServerShowAdvanced) {
                        TextField(
                            "SSH host (empty = auto from URL)",
                            text: $newServerSSHHost,
                            prompt: Text(autoSSHHost(from: newServerURL))
                        )
                        .autocorrectionDisabled()
                        TextField("SSH user", text: $newServerSSHUser)
                        TextField("SSH port", text: $newServerSSHPort)
                    }
                }

                if let error {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()

            HStack {
                if validatingServer {
                    ProgressView().controlSize(.small)
                    Text("Validating…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save and connect") {
                    Task { await saveNewServer() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validatingServer || !canSaveNewServer || !license.status.canCreateNew)
                .help(license.status.canCreateNew
                      ? ""
                      : "Trial expired — buy a license to add a new BorgBox server.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var canSaveNewServer: Bool {
        !newServerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newServerURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !newServerToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func autoSSHHost(from url: String) -> String {
        URLComponents(string: url)?.host ?? ""
    }

    private func saveNewServer() async {
        validatingServer = true
        defer { validatingServer = false }
        error = nil

        let cleanURL = newServerURL.trimmingCharacters(in: .whitespaces)
        let cleanToken = newServerToken.trimmingCharacters(in: .whitespaces)
        let cleanName = newServerName.trimmingCharacters(in: .whitespaces)

        let host = newServerSSHHost.trimmingCharacters(in: .whitespaces).isEmpty
            ? autoSSHHost(from: cleanURL)
            : newServerSSHHost.trimmingCharacters(in: .whitespaces)
        let port = Int(newServerSSHPort.trimmingCharacters(in: .whitespaces)) ?? 22
        let user = newServerSSHUser.trimmingCharacters(in: .whitespaces).isEmpty
            ? "borg"
            : newServerSSHUser.trimmingCharacters(in: .whitespaces)

        guard !host.isEmpty else {
            error = "Could not extract a host from the daemon URL. Set one under SSH (advanced)."
            return
        }

        do {
            try await BorgBoxClient.shared.health(daemonURL: cleanURL)
            _ = try await BorgBoxClient.shared.info(daemonURL: cleanURL, token: cleanToken)
        } catch {
            self.error = error.localizedDescription
            return
        }

        let server = BorgBoxServer(
            name: cleanName,
            daemonURL: cleanURL,
            sshHost: host,
            sshUser: user,
            sshPort: port
        )
        do {
            try serverStore.add(server, token: cleanToken)
            // Wipe the form fields so they don't linger in memory.
            newServerToken = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }

    private func formatUptime(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Actions

    private func loadAll(server: BorgBoxServer) async {
        loading = true
        defer { loading = false }
        error = nil

        // `repos` is the critical fetch — its failure is the only one that
        // should surface in red. The rest are optional "nice to have"
        // endpoints and their failures are swallowed silently so their cards
        // just stay hidden.
        async let statsResult = silentFetch { try await BorgBoxClient.shared.systemStats(server: server) }
        async let reposResult = criticalFetch { try await BorgBoxClient.shared.listRepos(server: server) }
        async let sessResult  = silentFetch { try await BorgBoxClient.shared.sessions(server: server) }
        async let jobsResult  = silentFetch { try await BorgBoxClient.shared.listJobs(server: server) }

        let (newStats, newRepos, newSessions, newJobs) = await (statsResult, reposResult, sessResult, jobsResult)
        stats = newStats
        sessions = newSessions ?? []
        if let newRepos { repos = newRepos }
        if let newJobs { jobsStore.hydrate(from: newJobs, server: server) }
    }

    private func criticalFetch<T>(_ op: () async throws -> T) async -> T? {
        do {
            return try await op()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func silentFetch<T>(_ op: () async throws -> T) async -> T? {
        do {
            return try await op()
        } catch {
            // Print so failures in optional cards (stats, sessions, jobs)
            // are still visible when running from Xcode — otherwise a decode
            // bug in one of them would just hide the card without any clue.
            print("[BorgBoxServerPanel] silent fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Import detection

    private func isAlreadyImported(_ remote: BorgBoxRemoteRepo) -> Bool {
        guard let server = serverStore.first else { return false }
        return repoStore.repositories.contains { local in
            repoMatchesRemote(local: local, remote: remote, server: server)
        }
    }

    /// Single source of truth for "does this local Repository point at that
    /// remote BorgBox repo?". Prefers the daemon's `ssh_url` when available
    /// (v0.3.0+), falls back to host + path matching for older daemons.
    private func repoMatchesRemote(
        local: Repository,
        remote: BorgBoxRemoteRepo,
        server: BorgBoxServer
    ) -> Bool {
        if let sshUrl = remote.sshUrl, !sshUrl.isEmpty, local.url == sshUrl {
            return true
        }
        return local.url.contains(server.sshHost) && local.url.hasSuffix(remote.path)
    }

    // MARK: - Passphrase resolution

    /// Resolves the borg passphrase for a given remote repo, in this order:
    /// 1. Per-panel session cache (in-memory, wiped when the panel closes).
    /// 2. BorgBox-namespaced Keychain entry (persisted across launches —
    ///    saved the first time the user types the passphrase into the prompt).
    /// 3. Local `Repository` whose SSH URL points at the same daemon host
    ///    and ends in `/<repoName>` — read non-interactively from Keychain.
    /// Returns nil only if all three miss; the caller falls back to a prompt.
    private func resolveLocalPassphrase(repoName: String, server: BorgBoxServer) -> String? {
        if let cached = sessionPassphrases[repoName] { return cached }

        if let stored = Keychain.borgBoxRepoPassphrase(serverId: server.id, repo: repoName) {
            return stored
        }

        let host = URL(string: server.daemonURL)?.host ?? ""
        let match = repoStore.repositories.first { repo in
            let url = repo.url
            return url.contains(host) && url.hasSuffix("/\(repoName)")
        }
        guard let match else { return nil }
        return Keychain.unattendedPassphrase(for: match.id)
    }

    private func withPassphrase(
        repo: String,
        action: String,
        server: BorgBoxServer,
        run: @escaping (String) -> Void
    ) {
        if let p = resolveLocalPassphrase(repoName: repo, server: server) {
            sessionPassphrases[repo] = p
            run(p)
            return
        }
        passphrasePrompt = PassphrasePrompt(
            repoName: repo,
            action: action,
            then: run
        )
    }

    // MARK: - Action starters

    private func startCheck(repo: String, server: BorgBoxServer) {
        withPassphrase(repo: repo, action: "Check", server: server) { pass in
            fireCheck(repo: repo, server: server, passphrase: pass)
        }
    }

    private func fireCheck(repo: String, server: BorgBoxServer, passphrase: String) {
        Task {
            do {
                let start = try await BorgBoxClient.shared.check(
                    server: server,
                    repo: repo,
                    passphrase: passphrase
                )
                jobsStore.register(initial: start, kind: "check", repo: repo, server: server)
            } catch BorgBoxError.http(404, _) {
                self.error = "The daemon doesn't implement /repos/\(repo)/check yet."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startPrune(repo: String, server: BorgBoxServer) {
        withPassphrase(repo: repo, action: "Prune", server: server) { pass in
            pruneTarget = PruneTarget(repo: repo, passphrase: pass)
        }
    }

    private func startArchives(repo: String, server: BorgBoxServer) {
        withPassphrase(repo: repo, action: "Archives", server: server) { pass in
            archivesTarget = ArchivesTarget(repo: repo, passphrase: pass)
        }
    }

    private func startCompact(repo: String, server: BorgBoxServer) {
        withPassphrase(repo: repo, action: "Compact", server: server) { pass in
            fireCompact(repo: repo, server: server, passphrase: pass)
        }
    }

    private func fireCompact(repo: String, server: BorgBoxServer, passphrase: String) {
        Task {
            do {
                let start = try await BorgBoxClient.shared.compact(
                    server: server,
                    repo: repo,
                    passphrase: passphrase
                )
                jobsStore.register(initial: start, kind: "compact", repo: repo, server: server)
            } catch BorgBoxError.http(404, _) {
                self.error = "The daemon doesn't implement /repos/\(repo)/compact yet."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func runBreakLock(repo: String, server: BorgBoxServer) {
        Task {
            do {
                try await BorgBoxClient.shared.breakLock(server: server, repo: repo)
                // Refresh sessions since break-lock typically follows a
                // stuck operation; the session list is the easiest thing to
                // visibly reflect the state change.
                await loadAll(server: server)
            } catch BorgBoxError.http(404, _) {
                self.error = "The daemon doesn't implement /repos/\(repo)/break-lock yet."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func runDelete(repo: String, server: BorgBoxServer) {
        Task {
            do {
                try await BorgBoxClient.shared.deleteRepo(server: server, repo: repo)
                Keychain.deleteBorgBoxRepoPassphrase(serverId: server.id, repo: repo)
                sessionPassphrases.removeValue(forKey: repo)
                removeLocalCounterpart(repoName: repo, server: server)
                await loadAll(server: server)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Removes any local `Repository` that points at the just-deleted remote,
    /// so the sidebar doesn't keep a dangling entry whose URL no longer exists.
    private func removeLocalCounterpart(repoName: String, server: BorgBoxServer) {
        let matches = repoStore.repositories.filter { local in
            local.url.contains(server.sshHost) && local.url.hasSuffix("/\(repoName)")
        }
        for local in matches {
            repoStore.remove(local)
        }
    }
}
