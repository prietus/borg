import Foundation

enum BorgBoxError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case apiError(String)
    case decode(String)
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The BorgBox daemon URL is not valid."
        case .invalidResponse:
            return "Invalid response from the BorgBox daemon."
        case .http(let code, let body):
            return "BorgBox returned HTTP \(code): \(body)"
        case .apiError(let msg):
            return "BorgBox: \(msg)"
        case .decode(let detail):
            return "Could not decode the daemon response: \(detail)"
        case .noToken:
            return "No token saved for this server."
        }
    }
}

struct BorgBoxInfo: Decodable, Hashable {
    let version: String
    let repoRoot: String?
    let freeBytes: Int64?
    let totalBytes: Int64?
    let uptimeSec: Int?
    let borgVersion: String?
    let goVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case repoRoot     = "repo_root"
        case freeBytes    = "free_bytes"
        case totalBytes   = "total_bytes"
        case uptimeSec    = "uptime_sec"
        case borgVersion  = "borg_version"
        case goVersion    = "go_version"
    }
}

struct BorgBoxRemoteRepo: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let sizeBytes: Int64?
    let initialized: Bool?
    let modifiedAt: String?
    /// Absolute `ssh://` URL as reported by the daemon (v0.3.0+). Built from
    /// BORGBOX_SSH_* env on the server side, so it reflects the true host
    /// reachable for borg even when the HTTP daemon URL uses a different name.
    let sshUrl: String?
    /// True when the repo is registered in `authorized_keys`. `false` means
    /// the directory exists under the repo root but no key is authorized —
    /// the user can adopt it via POST /repos/import. Older daemons omit the
    /// field, in which case we treat it as registered for backwards compat.
    let registered: Bool?
    /// Whether the repo's authorized_keys line forces `borg serve
    /// --append-only`. Added in the 2026-04-18 daemon build; older daemons
    /// omit the field, so it stays optional and the UI treats nil as
    /// "unknown / assume off".
    let appendOnly: Bool?

    var id: String { name }

    /// Effective registration flag: defaults to true when the daemon doesn't
    /// report the field (pre-v0.3.0) so the UI doesn't hide existing repos.
    var isRegistered: Bool { registered ?? true }

    enum CodingKeys: String, CodingKey {
        case name, path, initialized, registered
        case sizeBytes   = "size_bytes"
        case modifiedAt  = "modified_at"
        case sshUrl      = "ssh_url"
        case appendOnly  = "append_only"
    }
}

struct BorgBoxSystemStats: Decodable, Hashable {
    let hostname: String
    let uptimeSeconds: Int
    let load: [Double]
    let storage: Storage
    let borgboxVersion: String?

    struct Storage: Decodable, Hashable {
        let path: String
        let totalBytes: Int64
        let usedBytes: Int64
        let freeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case path
            case totalBytes = "total_bytes"
            case usedBytes  = "used_bytes"
            case freeBytes  = "free_bytes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case hostname, load, storage
        case uptimeSeconds  = "uptime_seconds"
        case borgboxVersion = "borgbox_version"
    }
}

struct BorgBoxSession: Decodable, Identifiable, Hashable {
    let pid: Int
    let repo: String
    let clientIp: String?
    let startedAt: String?
    let cpuPercent: Double?
    let rssBytes: Int64?

    var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, repo
        case clientIp   = "client_ip"
        case startedAt  = "started_at"
        case cpuPercent = "cpu_percent"
        case rssBytes   = "rss_bytes"
    }
}

struct BorgBoxJob: Decodable, Identifiable, Hashable {
    let id: String
    let repo: String?
    let kind: String
    let status: String
    let startedAt: String?
    let finishedAt: String?
    let exitCode: Int?
    let logTail: [String]?

    /// True when the daemon has reported a terminal state — the UI can stop
    /// polling.
    var isTerminal: Bool {
        switch status {
        case "succeeded", "failed", "done", "error", "cancelled":
            return true
        default:
            return false
        }
    }

    var isFailure: Bool {
        switch status {
        case "failed", "error", "cancelled":
            return true
        default:
            return exitCode.map { $0 != 0 } ?? false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, kind, status
        case startedAt  = "started_at"
        case finishedAt = "finished_at"
        case exitCode   = "exit_code"
        case logTail    = "log_tail"
    }
}

struct BorgBoxJobStart: Decodable, Hashable {
    let jobId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
    }
}

/// A single SSE payload from `/jobs/{id}/stream`. The daemon ships every
/// event as the same JSON shape with a `type` discriminator — we decode
/// into this and let the caller pattern-match on `type`.
struct BorgBoxJobStreamEvent: Decodable, Hashable {
    let type: String
    let line: String?
    let status: String?
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case type, line, status
        case exitCode = "exit_code"
    }
}

struct BorgBoxRemoteArchive: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String?
    let username: String?
    /// ISO-8601 timestamp of when the archive was created. Comes from the
    /// borg `time` field; the daemon may also expose `start` in older builds.
    let time: String?
    let comment: String?
    /// Optional richer fields kept for forward compatibility — v0.2.0 of the
    /// daemon doesn't return them, but newer builds may.
    let durationSeconds: Double?
    let nfiles: Int64?
    let originalSize: Int64?
    let compressedSize: Int64?
    let deduplicatedSize: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, username, time, comment, nfiles
        case durationSeconds  = "duration_seconds"
        case originalSize     = "original_size"
        case compressedSize   = "compressed_size"
        case deduplicatedSize = "deduplicated_size"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self, forKey: .id)
        name            = try c.decode(String.self, forKey: .name)
        hostname        = try c.decodeIfPresent(String.self, forKey: .hostname)
        username        = try c.decodeIfPresent(String.self, forKey: .username)
        time            = try c.decodeIfPresent(String.self, forKey: .time)
        comment         = try c.decodeIfPresent(String.self, forKey: .comment)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        nfiles          = try c.decodeIfPresent(Int64.self, forKey: .nfiles)
        originalSize    = try c.decodeIfPresent(Int64.self, forKey: .originalSize)
        compressedSize  = try c.decodeIfPresent(Int64.self, forKey: .compressedSize)
        deduplicatedSize = try c.decodeIfPresent(Int64.self, forKey: .deduplicatedSize)
    }
}

/// A maintenance schedule registered on a BorgBox daemon. The daemon's
/// additive scheduler API (v0.4.0+) stores `check` and `compact` schedules
/// per repo. Every field is always present in the wire JSON (no omitempty
/// on the server), so decoding is a direct mapping — `last_run`,
/// `last_status`, `last_job_id` come back as the empty string before the
/// schedule has fired for the first time.
///
/// `weekday` is 0..6 (Sunday..Saturday) and only meaningful when
/// `cadence == "weekly"`. `day` is 1..28 and only meaningful for
/// `"monthly"`. Both come back as 0 when the cadence doesn't use them.
struct BorgBoxSchedule: Decodable, Identifiable, Hashable {
    let id: String
    let repo: String
    /// `"check"` or `"compact"`. Not an enum on purpose — the daemon is the
    /// source of truth and might grow new kinds; the UI maps known values
    /// and shows the raw string for anything unexpected.
    let kind: String
    /// `"daily"`, `"weekly"` or `"monthly"`. Same reasoning as `kind`.
    let cadence: String
    let hour: Int
    let minute: Int
    let weekday: Int
    let day: Int
    let enabled: Bool
    let createdAt: String
    /// RFC3339 UTC timestamp of the most recent fire, or `""` if the
    /// schedule has never run.
    let lastRun: String
    /// One of `""`, `"running"`, `"done"`, `"error"`, `"skipped"`. Empty
    /// means the schedule has never fired.
    let lastStatus: String
    let lastJobId: String
    /// RFC3339 UTC timestamp of the next scheduled fire, calculated by the
    /// daemon. Empty only in pathological cases (e.g. invalid schedule).
    let nextRun: String

    enum CodingKeys: String, CodingKey {
        case id, repo, kind, cadence, hour, minute, weekday, day, enabled
        case createdAt  = "created_at"
        case lastRun    = "last_run"
        case lastStatus = "last_status"
        case lastJobId  = "last_job_id"
        case nextRun    = "next_run"
    }

    var lastRunDate: Date? { Self.parseRFC3339(lastRun) }
    var nextRunDate: Date? { Self.parseRFC3339(nextRun) }

    private static func parseRFC3339(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// A "stale repo" alert registered with the BorgBox daemon. The daemon
/// polls each repo's mtime on a tick and fires the alert's webhook when
/// the gap exceeds `staleAfterHours`. `hasSecret` tells us whether
/// outbound webhooks are HMAC-signed; the signing key itself is
/// write-only and never travels back to the client.
struct BorgBoxAlert: Decodable, Identifiable, Hashable {
    let id: String
    let repo: String
    let staleAfterHours: Int
    let webhookURL: String
    let enabled: Bool
    /// 0 means "never re-notify while the repo stays stale" — edge-triggered
    /// fire only. Any positive value is the minimum gap (in hours) between
    /// repeated `event: stale` deliveries while the stale state persists.
    let renotifyHours: Int
    /// Whether the daemon is currently configured to HMAC-sign this alert's
    /// webhook deliveries. We never see the secret itself.
    let hasSecret: Bool
    let createdAt: String
    let lastCheckAt: String
    /// `nil` before the first check; after that `"ok"` or `"stale"`.
    let lastState: String?
    let lastWrite: String
    let lastAlertedAt: String
    let lastError: String

    var lastCheckDate: Date?   { Self.parseRFC3339(lastCheckAt) }
    var lastWriteDate: Date?   { Self.parseRFC3339(lastWrite) }
    var lastAlertedDate: Date? { Self.parseRFC3339(lastAlertedAt) }

    private static func parseRFC3339(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, enabled
        case staleAfterHours = "stale_after_hours"
        case webhookURL      = "webhook_url"
        case renotifyHours   = "renotify_hours"
        case hasSecret       = "has_secret"
        case createdAt       = "created_at"
        case lastCheckAt     = "last_check_at"
        case lastState       = "last_state"
        case lastWrite       = "last_write"
        case lastAlertedAt   = "last_alerted_at"
        case lastError       = "last_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(String.self, forKey: .id)
        self.repo            = try c.decode(String.self, forKey: .repo)
        self.staleAfterHours = try c.decode(Int.self,    forKey: .staleAfterHours)
        self.webhookURL      = try c.decode(String.self, forKey: .webhookURL)
        self.enabled         = try c.decode(Bool.self,   forKey: .enabled)
        self.renotifyHours   = try c.decode(Int.self,    forKey: .renotifyHours)
        // `has_secret` shipped in daemon 0.6 — older builds omit it. Treat
        // a missing field as "no signing configured" so a mixed-version
        // rollout doesn't spuriously claim every alert is signed.
        self.hasSecret       = try c.decodeIfPresent(Bool.self, forKey: .hasSecret) ?? false
        self.createdAt       = try c.decode(String.self, forKey: .createdAt)
        self.lastCheckAt     = try c.decode(String.self, forKey: .lastCheckAt)
        // Back-compat: daemon <0.6 returned `""` here, not `null`. Treat an
        // empty string the same as a missing value so both wire formats
        // collapse onto the same Swift nil and the UI doesn't have two
        // "never checked" representations to special-case.
        let rawState = try c.decodeIfPresent(String.self, forKey: .lastState)
        self.lastState = (rawState?.isEmpty == true) ? nil : rawState
        self.lastWrite       = try c.decode(String.self, forKey: .lastWrite)
        self.lastAlertedAt   = try c.decode(String.self, forKey: .lastAlertedAt)
        self.lastError       = try c.decode(String.self, forKey: .lastError)
    }
}

struct BorgBoxKey: Decodable, Identifiable, Hashable {
    let fingerprint: String
    let comment: String?
    let algo: String?
    let addedAt: String?
    let lastUsedAt: String?

    var id: String { fingerprint }

    enum CodingKeys: String, CodingKey {
        case fingerprint, comment, algo
        case addedAt    = "added_at"
        case lastUsedAt = "last_used_at"
    }
}

struct BorgBoxAddedKey: Decodable, Hashable {
    let fingerprint: String
}

actor BorgBoxClient {
    static let shared = BorgBoxClient()

    private struct APIError: Decodable { let error: String }
    private struct CreateRepoBody: Encodable {
        let name: String
        let pubkey: String
    }

    // MARK: - Endpoints

    /// Hits `/health` with no auth. Used at server-add time to validate the URL.
    func health(daemonURL: String) async throws {
        let url = try endpoint(daemonURL: daemonURL, path: "health")
        let request = URLRequest(url: url)
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: Data())
    }

    /// Hits `/info` with auth. Used at server-add time to validate the token.
    func info(daemonURL: String, token: String) async throws -> BorgBoxInfo {
        try await get("info", daemonURL: daemonURL, token: token, decoding: BorgBoxInfo.self)
    }

    func listRepos(server: BorgBoxServer) async throws -> [BorgBoxRemoteRepo] {
        guard let token = Keychain.borgBoxToken(for: server.id) else {
            throw BorgBoxError.noToken
        }
        return try await get("repos", daemonURL: server.daemonURL, token: token, decoding: [BorgBoxRemoteRepo].self)
    }

    func createRepo(server: BorgBoxServer, name: String, pubkey: String) async throws -> BorgBoxRemoteRepo {
        guard let token = Keychain.borgBoxToken(for: server.id) else {
            throw BorgBoxError.noToken
        }
        let body = CreateRepoBody(name: name, pubkey: pubkey)
        return try await post(
            "repos",
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxRemoteRepo.self
        )
    }

    /// Adopts an existing repo directory under the daemon's repo root by
    /// adding a pubkey line to `authorized_keys`. Requires v0.3.0+.
    /// Does NOT run borg init — the repo must already be a valid borg repo.
    func importRepo(server: BorgBoxServer, name: String, pubkey: String) async throws -> BorgBoxRemoteRepo {
        let token = try tokenOrThrow(server)
        let body = CreateRepoBody(name: name, pubkey: pubkey)
        return try await post(
            "repos/import",
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxRemoteRepo.self
        )
    }

    func repoInfo(server: BorgBoxServer, repo: String) async throws -> BorgBoxRemoteRepo {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))"
        return try await get(path, daemonURL: server.daemonURL, token: token, decoding: BorgBoxRemoteRepo.self)
    }

    func deleteRepo(server: BorgBoxServer, repo: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))"
        try await deleteRequest(path, daemonURL: server.daemonURL, token: token)
    }

    // MARK: - System / sessions

    func systemStats(server: BorgBoxServer) async throws -> BorgBoxSystemStats {
        let token = try tokenOrThrow(server)
        return try await get("system/stats", daemonURL: server.daemonURL, token: token, decoding: BorgBoxSystemStats.self)
    }

    func sessions(server: BorgBoxServer) async throws -> [BorgBoxSession] {
        let token = try tokenOrThrow(server)
        return try await get("sessions", daemonURL: server.daemonURL, token: token, decoding: [BorgBoxSession].self)
    }

    // MARK: - Maintenance jobs

    private struct CheckBody: Encodable {
        let repair: Bool
        let verifyData: Bool
        let passphrase: String?
        enum CodingKeys: String, CodingKey {
            case repair, passphrase
            case verifyData = "verify_data"
        }
    }

    func check(
        server: BorgBoxServer,
        repo: String,
        passphrase: String?,
        repair: Bool = false,
        verifyData: Bool = false
    ) async throws -> BorgBoxJobStart {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/check"
        let body = CheckBody(repair: repair, verifyData: verifyData, passphrase: passphrase)
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxJobStart.self
        )
    }

    func job(server: BorgBoxServer, jobId: String) async throws -> BorgBoxJob {
        let token = try tokenOrThrow(server)
        let path = "jobs/\(encodeSegment(jobId))"
        return try await get(path, daemonURL: server.daemonURL, token: token, decoding: BorgBoxJob.self)
    }

    /// Opens an SSE subscription to `/jobs/{id}/stream` (v0.3.0+). The stream
    /// yields one `BorgBoxJobStreamEvent` per SSE block and finishes cleanly
    /// when the daemon sends `event: end`. The returned task is cancellable:
    /// dropping the stream or calling `.cancel()` on the enclosing Task tears
    /// down the underlying URL session task.
    nonisolated func streamJob(
        server: BorgBoxServer,
        jobId: String
    ) throws -> AsyncThrowingStream<BorgBoxJobStreamEvent, Error> {
        guard let token = Keychain.borgBoxToken(for: server.id) else {
            throw BorgBoxError.noToken
        }
        let url = try Self.streamEndpoint(daemonURL: server.daemonURL, jobId: jobId)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Long jobs (e.g. check on big repos) can run well past the default
        // 60s timeout — bump to an hour. The client Task is cancellable so
        // we don't lose the ability to stop early.
        request.timeoutInterval = 3600

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.checkStreamHTTP(response)
                    var currentEvent = "message"
                    var dataLines: [String] = []
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            // Blank line dispatches the accumulated event.
                            if !dataLines.isEmpty {
                                let joined = dataLines.joined(separator: "\n")
                                if let data = joined.data(using: .utf8),
                                   let ev = try? decoder.decode(BorgBoxJobStreamEvent.self, from: data) {
                                    continuation.yield(ev)
                                }
                            }
                            currentEvent = "message"
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix(":") {
                            continue // heartbeat / comment
                        }
                        if let colon = line.firstIndex(of: ":") {
                            let field = String(line[..<colon])
                            var value = String(line[line.index(after: colon)...])
                            if value.hasPrefix(" ") { value.removeFirst() }
                            switch field {
                            case "event":
                                currentEvent = value
                            case "data":
                                dataLines.append(value)
                            default:
                                break
                            }
                        }
                        if currentEvent == "end" {
                            // Drain one more empty-line dispatch then exit.
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamEndpoint(daemonURL: String, jobId: String) throws -> URL {
        guard var components = URLComponents(string: daemonURL) else {
            throw BorgBoxError.invalidURL
        }
        let existing = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        let segments = [existing, "api", "v1", "jobs", encoded, "stream"].filter { !$0.isEmpty }
        components.path = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            throw BorgBoxError.invalidURL
        }
        return url
    }

    private static func checkStreamHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BorgBoxError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            throw BorgBoxError.http(http.statusCode, "")
        }
    }

    func listJobs(server: BorgBoxServer) async throws -> [BorgBoxJob] {
        let token = try tokenOrThrow(server)
        return try await get("jobs", daemonURL: server.daemonURL, token: token, decoding: [BorgBoxJob].self)
    }

    private struct PruneBody: Encodable {
        let keepDaily: Int
        let keepWeekly: Int
        let keepMonthly: Int
        let keepYearly: Int
        let dryRun: Bool
        let passphrase: String?
        enum CodingKeys: String, CodingKey {
            case passphrase
            case keepDaily   = "keep_daily"
            case keepWeekly  = "keep_weekly"
            case keepMonthly = "keep_monthly"
            case keepYearly  = "keep_yearly"
            case dryRun      = "dry_run"
        }
    }

    func prune(
        server: BorgBoxServer,
        repo: String,
        passphrase: String?,
        keepDaily: Int,
        keepWeekly: Int,
        keepMonthly: Int,
        keepYearly: Int,
        dryRun: Bool
    ) async throws -> BorgBoxJobStart {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/prune"
        let body = PruneBody(
            keepDaily: keepDaily,
            keepWeekly: keepWeekly,
            keepMonthly: keepMonthly,
            keepYearly: keepYearly,
            dryRun: dryRun,
            passphrase: passphrase
        )
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxJobStart.self
        )
    }

    private struct CompactBody: Encodable {
        let passphrase: String?
    }

    func compact(
        server: BorgBoxServer,
        repo: String,
        passphrase: String?
    ) async throws -> BorgBoxJobStart {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/compact"
        let body = CompactBody(passphrase: passphrase)
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxJobStart.self
        )
    }

    func breakLock(server: BorgBoxServer, repo: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/break-lock"
        try await postNoBodyNoContent(path, daemonURL: server.daemonURL, token: token)
    }

    // MARK: - Remote archives

    func remoteArchives(
        server: BorgBoxServer,
        repo: String,
        passphrase: String?
    ) async throws -> [BorgBoxRemoteArchive] {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/archives"
        var extraHeaders: [String: String] = [:]
        if let passphrase {
            extraHeaders["X-Borg-Passphrase"] = passphrase
        }
        return try await get(
            path,
            daemonURL: server.daemonURL,
            token: token,
            extraHeaders: extraHeaders,
            decoding: [BorgBoxRemoteArchive].self
        )
    }

    // MARK: - Per-repo SSH keys

    func listKeys(server: BorgBoxServer, repo: String) async throws -> [BorgBoxKey] {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/keys"
        return try await get(path, daemonURL: server.daemonURL, token: token, decoding: [BorgBoxKey].self)
    }

    private struct AddKeyBody: Encodable {
        let publicKey: String
        let comment: String?
        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case comment
        }
    }

    func addKey(
        server: BorgBoxServer,
        repo: String,
        publicKey: String,
        comment: String?
    ) async throws -> BorgBoxAddedKey {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/keys"
        let body = AddKeyBody(publicKey: publicKey, comment: comment)
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxAddedKey.self
        )
    }

    func deleteKey(server: BorgBoxServer, repo: String, fingerprint: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/keys/\(encodeSegment(fingerprint))"
        try await deleteRequest(path, daemonURL: server.daemonURL, token: token)
    }

    // MARK: - Schedules (daemon scheduler, v0.4.0+)

    /// Body for `POST /repos/{name}/schedules` and `PATCH /schedules/{id}`.
    /// The daemon ignores id/repo/created_at/last_*/next_run even if sent,
    /// and for PATCH any omitted field keeps its current value — we use
    /// optionals with `encodeIfPresent` so callers can send partial patches
    /// (e.g. just `{"enabled": false}` for the row toggle).
    private struct ScheduleBody: Encodable {
        var kind: String?
        var cadence: String?
        var hour: Int?
        var minute: Int?
        var weekday: Int?
        var day: Int?
        var enabled: Bool?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(kind,    forKey: .kind)
            try c.encodeIfPresent(cadence, forKey: .cadence)
            try c.encodeIfPresent(hour,    forKey: .hour)
            try c.encodeIfPresent(minute,  forKey: .minute)
            try c.encodeIfPresent(weekday, forKey: .weekday)
            try c.encodeIfPresent(day,     forKey: .day)
            try c.encodeIfPresent(enabled, forKey: .enabled)
        }

        enum CodingKeys: String, CodingKey {
            case kind, cadence, hour, minute, weekday, day, enabled
        }
    }

    func listSchedules(server: BorgBoxServer) async throws -> [BorgBoxSchedule] {
        let token = try tokenOrThrow(server)
        return try await get(
            "schedules",
            daemonURL: server.daemonURL,
            token: token,
            decoding: [BorgBoxSchedule].self
        )
    }

    func schedulesForRepo(
        server: BorgBoxServer,
        repo: String
    ) async throws -> [BorgBoxSchedule] {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/schedules"
        return try await get(
            path,
            daemonURL: server.daemonURL,
            token: token,
            decoding: [BorgBoxSchedule].self
        )
    }

    func getSchedule(server: BorgBoxServer, id: String) async throws -> BorgBoxSchedule {
        let token = try tokenOrThrow(server)
        let path = "schedules/\(encodeSegment(id))"
        return try await get(
            path,
            daemonURL: server.daemonURL,
            token: token,
            decoding: BorgBoxSchedule.self
        )
    }

    func createSchedule(
        server: BorgBoxServer,
        repo: String,
        kind: String,
        cadence: String,
        hour: Int,
        minute: Int,
        weekday: Int,
        day: Int,
        enabled: Bool
    ) async throws -> BorgBoxSchedule {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/schedules"
        let body = ScheduleBody(
            kind: kind,
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            day: day,
            enabled: enabled
        )
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxSchedule.self
        )
    }

    /// Partial update. Any argument left nil is omitted from the body, so
    /// the daemon keeps the current value. When cadence/hour/minute/weekday/
    /// day change the server recalculates `next_run`; a bare `enabled`
    /// toggle does not, which is deliberate so disabling/re-enabling
    /// doesn't reset the schedule.
    func updateSchedule(
        server: BorgBoxServer,
        id: String,
        kind: String? = nil,
        cadence: String? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        weekday: Int? = nil,
        day: Int? = nil,
        enabled: Bool? = nil
    ) async throws -> BorgBoxSchedule {
        let token = try tokenOrThrow(server)
        let path = "schedules/\(encodeSegment(id))"
        let body = ScheduleBody(
            kind: kind,
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            day: day,
            enabled: enabled
        )
        return try await patch(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxSchedule.self
        )
    }

    func deleteSchedule(server: BorgBoxServer, id: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "schedules/\(encodeSegment(id))"
        try await deleteRequest(path, daemonURL: server.daemonURL, token: token)
    }

    // MARK: - Stale alerts (daemon, 2026-04-18)

    /// Body for `POST /repos/{name}/alerts` and `PATCH /alerts/{id}`.
    /// `encodeIfPresent` lets callers send partial patches — e.g. just
    /// `{"enabled": false}` when toggling from the list row — without
    /// stomping fields the user didn't touch.
    private struct AlertBody: Encodable {
        var staleAfterHours: Int?
        var webhookURL: String?
        var enabled: Bool?
        var renotifyHours: Int?
        // Secret semantics on the wire (PATCH): omitted = leave unchanged;
        // `""` = clear; non-empty = set. `nil` here maps to omitted; pass
        // "" explicitly to clear.
        var secret: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(staleAfterHours, forKey: .staleAfterHours)
            try c.encodeIfPresent(webhookURL,      forKey: .webhookURL)
            try c.encodeIfPresent(enabled,         forKey: .enabled)
            try c.encodeIfPresent(renotifyHours,   forKey: .renotifyHours)
            try c.encodeIfPresent(secret,          forKey: .secret)
        }

        enum CodingKeys: String, CodingKey {
            case enabled, secret
            case staleAfterHours = "stale_after_hours"
            case webhookURL      = "webhook_url"
            case renotifyHours   = "renotify_hours"
        }
    }

    private struct AlertTestResponse: Decodable { let status: String }

    func listAlerts(server: BorgBoxServer) async throws -> [BorgBoxAlert] {
        let token = try tokenOrThrow(server)
        return try await get(
            "alerts",
            daemonURL: server.daemonURL,
            token: token,
            decoding: [BorgBoxAlert].self
        )
    }

    func alertsForRepo(
        server: BorgBoxServer,
        repo: String
    ) async throws -> [BorgBoxAlert] {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/alerts"
        return try await get(
            path,
            daemonURL: server.daemonURL,
            token: token,
            decoding: [BorgBoxAlert].self
        )
    }

    func getAlert(server: BorgBoxServer, id: String) async throws -> BorgBoxAlert {
        let token = try tokenOrThrow(server)
        let path = "alerts/\(encodeSegment(id))"
        return try await get(
            path,
            daemonURL: server.daemonURL,
            token: token,
            decoding: BorgBoxAlert.self
        )
    }

    func createAlert(
        server: BorgBoxServer,
        repo: String,
        staleAfterHours: Int,
        webhookURL: String,
        enabled: Bool,
        renotifyHours: Int,
        secret: String? = nil
    ) async throws -> BorgBoxAlert {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))/alerts"
        // An empty string from the caller means "no signing" — same as nil,
        // just don't send the field so the daemon doesn't treat "" as a
        // deliberate clear operation.
        let normalizedSecret = (secret?.isEmpty == true) ? nil : secret
        let body = AlertBody(
            staleAfterHours: staleAfterHours,
            webhookURL: webhookURL,
            enabled: enabled,
            renotifyHours: renotifyHours,
            secret: normalizedSecret
        )
        return try await post(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxAlert.self
        )
    }

    /// Partial update. Any argument left nil is omitted from the body,
    /// so the daemon keeps the current value. This is the same
    /// "send-what-changed" pattern used by `updateSchedule`.
    ///
    /// `secret` has three states on the wire: nil (omit → leave unchanged),
    /// `""` (clear the secret → stop signing), or a non-empty string (set
    /// or rotate). Callers can pass `""` to disable signing on an alert
    /// that previously had a secret.
    func updateAlert(
        server: BorgBoxServer,
        id: String,
        staleAfterHours: Int? = nil,
        webhookURL: String? = nil,
        enabled: Bool? = nil,
        renotifyHours: Int? = nil,
        secret: String? = nil
    ) async throws -> BorgBoxAlert {
        let token = try tokenOrThrow(server)
        let path = "alerts/\(encodeSegment(id))"
        let body = AlertBody(
            staleAfterHours: staleAfterHours,
            webhookURL: webhookURL,
            enabled: enabled,
            renotifyHours: renotifyHours,
            secret: secret
        )
        return try await patch(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxAlert.self
        )
    }

    func deleteAlert(server: BorgBoxServer, id: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "alerts/\(encodeSegment(id))"
        try await deleteRequest(path, daemonURL: server.daemonURL, token: token)
    }

    /// Synchronously fires one `event: "test"` delivery against the
    /// configured webhook. Returns on 2xx (`{"status":"ok"}`); throws
    /// `BorgBoxError.apiError(...)` with the daemon's reason string when
    /// the webhook rejects (e.g. `"webhook returned 404"`), so the UI
    /// can show ✅/❌ with a meaningful message.
    func testAlert(server: BorgBoxServer, id: String) async throws {
        let token = try tokenOrThrow(server)
        let path = "alerts/\(encodeSegment(id))/test"
        _ = try await postNoBody(
            path,
            daemonURL: server.daemonURL,
            token: token,
            decoding: AlertTestResponse.self
        )
    }

    // MARK: - Repo append-only toggle (daemon, 2026-04-18)

    private struct RepoUpdateBody: Encodable {
        let appendOnly: Bool?
        enum CodingKeys: String, CodingKey {
            case appendOnly = "append_only"
        }
    }

    /// PATCHes an existing repo's metadata. Currently only exposes the
    /// `append_only` flag; the daemon stays responsible for rewriting the
    /// authorized_keys line, so the client just forwards the boolean.
    func updateRepo(
        server: BorgBoxServer,
        repo: String,
        appendOnly: Bool
    ) async throws -> BorgBoxRemoteRepo {
        let token = try tokenOrThrow(server)
        let path = "repos/\(encodeSegment(repo))"
        let body = RepoUpdateBody(appendOnly: appendOnly)
        return try await patch(
            path,
            daemonURL: server.daemonURL,
            token: token,
            body: body,
            decoding: BorgBoxRemoteRepo.self
        )
    }

    // MARK: - Token helpers

    private func tokenOrThrow(_ server: BorgBoxServer) throws -> String {
        guard let token = Keychain.borgBoxToken(for: server.id) else {
            throw BorgBoxError.noToken
        }
        return token
    }

    private func encodeSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - HTTP plumbing

    private func endpoint(daemonURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: daemonURL) else {
            throw BorgBoxError.invalidURL
        }
        let existing = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = [existing, "api", "v1", path].filter { !$0.isEmpty }
        components.path = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            throw BorgBoxError.invalidURL
        }
        return url
    }

    private func get<T: Decodable>(
        _ path: String,
        daemonURL: String,
        token: String,
        extraHeaders: [String: String] = [:],
        decoding: T.Type
    ) async throws -> T {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return try Self.decode(T.self, from: data)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        daemonURL: String,
        token: String,
        body: Body,
        decoding: T.Type
    ) async throws -> T {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return try Self.decode(T.self, from: data)
    }

    private func patch<Body: Encodable, T: Decodable>(
        _ path: String,
        daemonURL: String,
        token: String,
        body: Body,
        decoding: T.Type
    ) async throws -> T {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return try Self.decode(T.self, from: data)
    }

    /// POST with no request body, decoding a response. Used by operations
    /// like `compact` that take no parameters but return a job id.
    private func postNoBody<T: Decodable>(
        _ path: String,
        daemonURL: String,
        token: String,
        decoding: T.Type
    ) async throws -> T {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return try Self.decode(T.self, from: data)
    }

    /// POST with no request body and no response body — used for `break-lock`
    /// which returns 204 No Content.
    private func postNoBodyNoContent(
        _ path: String,
        daemonURL: String,
        token: String
    ) async throws {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
    }

    /// DELETE with no response body. Used by `deleteKey`.
    private func deleteRequest(
        _ path: String,
        daemonURL: String,
        token: String
    ) async throws {
        let url = try endpoint(daemonURL: daemonURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw BorgBoxError.decode(
                "missing key '\(key.stringValue)' (\(ctx.debugDescription)). Response: \(preview)"
            )
        } catch let DecodingError.typeMismatch(_, ctx) {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw BorgBoxError.decode("wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription). Response: \(preview)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw BorgBoxError.decode("null value at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription). Response: \(preview)")
        } catch {
            throw BorgBoxError.decode(String(describing: error))
        }
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BorgBoxError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) { return }
        if let apiErr = try? JSONDecoder().decode(APIError.self, from: data) {
            throw BorgBoxError.apiError(apiErr.error)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw BorgBoxError.http(http.statusCode, String(text.prefix(400)))
    }
}
