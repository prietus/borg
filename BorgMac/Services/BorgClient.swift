import Foundation

/// Snapshot of a `borg create --progress --log-json` tick. Borg emits one
/// `archive_progress` event per file (throttled internally to ~1/s)
/// containing the cumulative byte counts, the running file count, and
/// the path currently being processed. The runner publishes this to
/// `BackupRunStatus` so the menu bar and schedule UI can render a
/// progress bar and ETA.
struct BorgProgress: Sendable {
    let originalBytes: Int64
    let compressedBytes: Int64
    let dedupedBytes: Int64
    let fileCount: Int
    let currentPath: String
}

enum BorgError: LocalizedError {
    case binaryNotFound
    case missingPassphrase
    case nonZeroExit(code: Int32, stderr: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Could not find the borg binary. Install it with 'brew install borgbackup'."
        case .missingPassphrase:
            return "Could not unlock the repository passphrase."
        case .nonZeroExit(let code, let stderr):
            return "borg failed (code \(code)): \(stderr)"
        case .decode(let msg):
            return "Could not decode borg's response: \(msg)"
        }
    }
}

actor BorgClient {
    static let shared = BorgClient()

    private var passphraseCache: [UUID: String] = [:]

    private let candidatePaths = [
        "/opt/homebrew/bin/borg",
        "/usr/local/bin/borg",
        "/opt/local/bin/borg",
        "/usr/bin/borg",
    ]

    nonisolated var binaryPath: String? {
        let paths = [
            "/opt/homebrew/bin/borg",
            "/usr/local/bin/borg",
            "/opt/local/bin/borg",
            "/usr/bin/borg",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Clears the in-memory passphrase cache — call on lock, logout, etc.
    func forgetPassphrases() {
        passphraseCache.removeAll()
    }

    func forget(repoId: UUID) {
        passphraseCache.removeValue(forKey: repoId)
    }

    /// Runs `borg info --json` against the repo with the supplied passphrase,
    /// bypassing the cache and Keychain lookup. Used by the "Update passphrase"
    /// sheet to verify that a new passphrase actually opens the repo before
    /// writing it to the Keychain.
    func verifyPassphrase(repo: Repository, passphrase: String) async throws {
        _ = try await run(
            ["info", "--json", repo.url],
            passphrase: passphrase,
            sshKeyPath: repo.sshKeyPath
        )
    }

    // MARK: - High level

    func listArchives(repo: Repository) async throws -> [Archive] {
        let pass = try await passphrase(for: repo)
        let data = try await run(
            ["list", "--json", repo.url],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
        do {
            return try JSONDecoder().decode(ArchiveListResponse.self, from: data).archives
        } catch {
            throw BorgError.decode(String(describing: error))
        }
    }

    /// Runs `borg info --json <repo>` and returns the repository-level stats
    /// (original / compressed / deduplicated sizes, archive count, encryption).
    /// Used by the stats panel to compute dedup/compression ratios.
    func info(repo: Repository) async throws -> BorgRepoInfo {
        let pass = try await passphrase(for: repo)
        let data = try await run(
            ["info", "--json", repo.url],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
        do {
            return try JSONDecoder().decode(BorgRepoInfo.self, from: data)
        } catch {
            throw BorgError.decode(String(describing: error))
        }
    }

    /// Initialize a brand new Borg repository at the given URL with the given
    /// passphrase. Used by the quick-setup wizard. Doesn't go through the
    /// passphrase cache because the repo doesn't exist in the local store yet.
    func initRepo(
        url: String,
        passphrase: String,
        encryption: String = "repokey-blake2",
        sshKeyPath: String? = nil
    ) async throws {
        _ = try await run(
            ["init", "--encryption", encryption, url],
            passphrase: passphrase,
            sshKeyPath: sshKeyPath
        )
    }

    /// Streams the file manifest of a single archive via `borg list --json-lines`.
    func listArchiveEntries(repo: Repository, archive: String) async throws -> [ArchiveEntry] {
        let pass = try await passphrase(for: repo)
        let data = try await run(
            ["list", "--json-lines", "\(repo.url)::\(archive)"],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
        let decoder = JSONDecoder()
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(4096)
        // Iterate over raw bytes to avoid creating one giant Swift String.
        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start..<data.endIndex].firstIndex(of: 0x0A) else {
                if start < data.endIndex,
                   let entry = try? decoder.decode(ArchiveEntry.self, from: data[start..<data.endIndex]) {
                    entries.append(entry)
                }
                break
            }
            let slice = data[start..<newline]
            if !slice.isEmpty,
               let entry = try? decoder.decode(ArchiveEntry.self, from: slice) {
                entries.append(entry)
            }
            start = data.index(after: newline)
        }
        return entries
    }

    /// Extracts a single file to a temporary location and returns its URL.
    /// Used for QuickLook previews.
    func extractToTemp(repo: Repository, archive: String, entryPath: String) async throws -> URL {
        let pass = try await passphrase(for: repo)
        let data = try await run(
            ["extract", "--stdout", "\(repo.url)::\(archive)", entryPath],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BorgMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let filename = entryPath.split(separator: "/").last.map(String.init) ?? "preview"
        let destination = tmpDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return destination
    }

    func createBackup(
        repo: Repository,
        archiveName: String,
        paths: [String],
        excludes: [String] = []
    ) async throws {
        let pass = try await passphrase(for: repo)
        var args = ["create", "--stats", "--compression", "lz4"]
        for pattern in excludes where !pattern.isEmpty {
            args += ["--exclude", pattern]
        }
        args.append("\(repo.url)::\(archiveName)")
        args.append(contentsOf: paths)
        _ = try await run(args, passphrase: pass, sshKeyPath: repo.sshKeyPath)
    }

    /// Create backup with an externally supplied passphrase — skips the
    /// Keychain/biometric path. Used by scheduled runs under launchd.
    /// When `onProgress` is non-nil, passes `--log-json --progress` so
    /// borg emits `archive_progress` events on stderr and the runner
    /// can write a live status file consumed by the menu bar.
    func createBackupUnattended(
        repo: Repository,
        passphrase: String,
        archiveName: String,
        paths: [String],
        excludes: [String] = [],
        onProgress: (@Sendable (BorgProgress) -> Void)? = nil,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async throws {
        var args = ["create", "--stats", "--compression", "lz4"]
        if onProgress != nil {
            args += ["--log-json", "--progress"]
        }
        for pattern in excludes where !pattern.isEmpty {
            args += ["--exclude", pattern]
        }
        args.append("\(repo.url)::\(archiveName)")
        args.append(contentsOf: paths)

        if let onProgress {
            _ = try await runWithStderrStream(
                args,
                passphrase: passphrase,
                sshKeyPath: repo.sshKeyPath,
                onLaunch: onLaunch
            ) { line in
                if let progress = Self.parseProgressLine(line) {
                    onProgress(progress)
                }
            }
        } else {
            _ = try await run(
                args,
                passphrase: passphrase,
                sshKeyPath: repo.sshKeyPath,
                onLaunch: onLaunch
            )
        }
    }

    /// Turns raw borg stderr into something worth showing a human. With
    /// `--log-json` borg emits one JSON object per line on stderr (mixing
    /// `archive_progress` ticks with `log_message` entries), so a failed
    /// run would otherwise dump a wall of JSON into `lastError`. We walk
    /// the lines, pull `.message` out of each `log_message` record, drop
    /// the progress ticks, and keep any non-JSON lines verbatim. If the
    /// stream wasn't JSON at all the input is returned unchanged.
    static func sanitizeStderr(_ raw: String) -> String {
        let trimmedWhole = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhole.isEmpty { return "" }
        var messages: [String] = []
        var sawJSON = false
        for rawLine in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("{"),
               let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sawJSON = true
                let type = obj["type"] as? String
                if type == "archive_progress" { continue }
                if let msg = (obj["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !msg.isEmpty {
                    messages.append(msg)
                }
                continue
            }
            messages.append(line)
        }
        if !sawJSON { return trimmedWhole }
        if messages.isEmpty { return trimmedWhole }
        // De-duplicate consecutive identical lines (borg repeats the same
        // "Remote:" banner several times over a session) to keep the UI
        // surface tight.
        var deduped: [String] = []
        for m in messages where deduped.last != m {
            deduped.append(m)
        }
        return deduped.joined(separator: "\n")
    }

    /// Parses a single stderr line from `borg create --log-json --progress`.
    /// Only `archive_progress` events return a value; everything else
    /// (log messages, summary, blank) returns nil and is ignored.
    private static func parseProgressLine(_ line: String) -> BorgProgress? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "archive_progress" else {
            return nil
        }
        let original = (obj["original_size"] as? NSNumber)?.int64Value ?? 0
        let compressed = (obj["compressed_size"] as? NSNumber)?.int64Value ?? 0
        let deduped = (obj["deduplicated_size"] as? NSNumber)?.int64Value ?? 0
        let nfiles = (obj["nfiles"] as? NSNumber)?.intValue ?? 0
        let path = (obj["path"] as? String) ?? ""
        return BorgProgress(
            originalBytes: original,
            compressedBytes: compressed,
            dedupedBytes: deduped,
            fileCount: nfiles,
            currentPath: path
        )
    }

    /// Prune + compact with an externally supplied passphrase. Used by
    /// scheduled runs when the schedule has retention configured.
    func pruneUnattended(
        repo: Repository,
        passphrase: String,
        keepDaily: Int,
        keepWeekly: Int,
        keepMonthly: Int
    ) async throws {
        var args = ["prune", "--list"]
        if keepDaily > 0 { args += ["--keep-daily", String(keepDaily)] }
        if keepWeekly > 0 { args += ["--keep-weekly", String(keepWeekly)] }
        if keepMonthly > 0 { args += ["--keep-monthly", String(keepMonthly)] }
        args.append(repo.url)
        _ = try await run(args, passphrase: passphrase, sshKeyPath: repo.sshKeyPath)
        _ = try? await run(["compact", repo.url], passphrase: passphrase, sshKeyPath: repo.sshKeyPath)
    }

    func extract(repo: Repository, archive: String, into destination: URL) async throws {
        let pass = try await passphrase(for: repo)
        _ = try await run(
            ["extract", "\(repo.url)::\(archive)"],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath,
            workingDirectory: destination
        )
    }

    func mount(repo: Repository, archive: String, at mountpoint: URL) async throws {
        let pass = try await passphrase(for: repo)
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        _ = try await run(
            ["mount", "\(repo.url)::\(archive)", mountpoint.path],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
    }

    func umount(at mountpoint: URL) async throws {
        _ = try await run(["umount", mountpoint.path], passphrase: nil)
    }

    /// Deletes a single archive from a repo (`borg delete <repo>::<archive>`).
    /// Disk space isn't reclaimed until the next `compact` run — the
    /// caller UI is expected to surface that caveat to the user.
    func deleteArchive(repo: Repository, archive: String) async throws {
        let pass = try await passphrase(for: repo)
        _ = try await run(
            ["delete", "\(repo.url)::\(archive)"],
            passphrase: pass,
            sshKeyPath: repo.sshKeyPath
        )
    }

    func prune(repo: Repository, keepDaily: Int, keepWeekly: Int, keepMonthly: Int) async throws {
        let pass = try await passphrase(for: repo)
        var args = ["prune", "--list"]
        if keepDaily > 0 { args += ["--keep-daily", String(keepDaily)] }
        if keepWeekly > 0 { args += ["--keep-weekly", String(keepWeekly)] }
        if keepMonthly > 0 { args += ["--keep-monthly", String(keepMonthly)] }
        args.append(repo.url)
        _ = try await run(args, passphrase: pass, sshKeyPath: repo.sshKeyPath)
        _ = try? await run(["compact", repo.url], passphrase: pass, sshKeyPath: repo.sshKeyPath)
    }

    // MARK: - Passphrase resolution

    /// Returns a cached passphrase or prompts via Keychain (Touch ID / password).
    /// Throws `BorgError.missingPassphrase` if the user cancels or it is missing.
    private func passphrase(for repo: Repository) async throws -> String {
        if let cached = passphraseCache[repo.id] {
            return cached
        }
        let reason = "Unlock the repository \(repo.name)"
        guard let p = await Keychain.passphrase(for: repo.id, reason: reason) else {
            throw BorgError.missingPassphrase
        }
        passphraseCache[repo.id] = p
        return p
    }

    /// Variant of `run` that forwards each line of stderr to a handler
    /// as borg emits it, instead of buffering the whole pipe until exit.
    /// Used by `createBackupUnattended` with `--log-json --progress` so
    /// the caller can publish a live `BorgProgress` stream.
    ///
    /// Stdout is still collected in full and returned. If borg exits
    /// non-zero, the accumulated stderr (the raw lines joined back)
    /// becomes the error message, so the failure surface is identical
    /// to `run`.
    @discardableResult
    private func runWithStderrStream(
        _ args: [String],
        passphrase: String?,
        sshKeyPath: String? = nil,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        guard let bin = binaryPath else { throw BorgError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = (extras + [existingPath]).joined(separator: ":")
        if let passphrase {
            env["BORG_PASSPHRASE"] = passphrase
        }
        if let sshKeyPath {
            env["BORG_RSH"] = "ssh -i \(sshKeyPath) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        }
        env["BORG_RELOCATED_REPO_ACCESS_IS_OK"] = "yes"
        env["BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK"] = "yes"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Thread-safe stderr accumulator — we buffer partial lines across
        // reads and remember everything in case the exit is non-zero and
        // we need to surface the error text to the caller.
        final class StderrBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var leftover = ""
            private var full = Data()

            func append(_ chunk: Data, lineHandler: (String) -> Void) {
                guard let text = String(data: chunk, encoding: .utf8) else {
                    lock.lock(); full.append(chunk); lock.unlock()
                    return
                }
                lock.lock()
                full.append(chunk)
                leftover += text
                var lines: [String] = []
                while let nl = leftover.firstIndex(of: "\n") {
                    lines.append(String(leftover[..<nl]))
                    leftover = String(leftover[leftover.index(after: nl)...])
                }
                lock.unlock()
                for line in lines where !line.isEmpty {
                    lineHandler(line)
                }
            }

            func finish(lineHandler: (String) -> Void) {
                lock.lock()
                let tail = leftover
                leftover = ""
                lock.unlock()
                if !tail.isEmpty { lineHandler(tail) }
            }

            func snapshot() -> Data {
                lock.lock(); defer { lock.unlock() }
                return full
            }
        }
        let buffer = StderrBuffer()

        try process.run()
        let pid = process.processIdentifier
        onLaunch?(pid)

        // Stream stderr via readabilityHandler so each tick emits
        // progress without waiting for process exit.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            buffer.append(data, lineHandler: onStderrLine)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global().async {
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    // Drain anything pending on stderr and detach the
                    // handler so the pipe can be closed.
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let tail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty {
                        buffer.append(tail, lineHandler: onStderrLine)
                    }
                    buffer.finish(lineHandler: onStderrLine)

                    // Borg exit codes: 0 = success, 1 = warnings (the
                    // operation still completed — e.g. an SSH banner
                    // from BorgBase or Errno-13 on a few unreadable
                    // files), 2+ = real error. Treat 1 as success so
                    // scheduled runs stop reporting perfectly fine
                    // backups as failures.
                    let code = process.terminationStatus
                    if code == 0 || code == 1 {
                        cont.resume(returning: outData)
                    } else {
                        let errStr = String(data: buffer.snapshot(), encoding: .utf8) ?? ""
                        cont.resume(throwing: BorgError.nonZeroExit(
                            code: code,
                            stderr: Self.sanitizeStderr(errStr)
                        ))
                    }
                }
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(
        _ args: [String],
        passphrase: String?,
        sshKeyPath: String? = nil,
        workingDirectory: URL? = nil,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> Data {
        guard let bin = binaryPath else { throw BorgError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = (extras + [existingPath]).joined(separator: ":")
        if let passphrase {
            env["BORG_PASSPHRASE"] = passphrase
        }
        if let sshKeyPath {
            env["BORG_RSH"] = "ssh -i \(sshKeyPath) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        }
        env["BORG_RELOCATED_REPO_ACCESS_IS_OK"] = "yes"
        env["BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK"] = "yes"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Captured by the cancellation handler below; `Process` itself isn't
        // Sendable, so we forward the pid to `kill(2)` instead of the instance.
        let pid = process.processIdentifier
        onLaunch?(pid)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global().async {
                    outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.wait()
                    // Borg exit 1 = warnings (operation still
                    // completed). Treat as success, same as the
                    // streaming path above.
                    let code = process.terminationStatus
                    if code == 0 || code == 1 {
                        cont.resume(returning: outData)
                    } else {
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        cont.resume(throwing: BorgError.nonZeroExit(
                            code: code,
                            stderr: Self.sanitizeStderr(errStr)
                        ))
                    }
                }
            }
        } onCancel: {
            // Borg traps SIGTERM and writes a checkpoint before exiting, so
            // the repo is left in a clean state. We forward via kill(2) to
            // stay Sendable-safe (Process isn't Sendable).
            kill(pid, SIGTERM)
        }
    }
}
