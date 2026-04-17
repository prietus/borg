import Foundation

enum BorgBaseError: LocalizedError {
    case noToken
    case invalidResponse
    case http(Int, String)
    case graphql(String)
    case unauthenticated

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No BorgBase API token configured."
        case .invalidResponse:
            return "Invalid response from the BorgBase server."
        case .http(let code, let body):
            return "BorgBase returned HTTP \(code): \(body)"
        case .graphql(let msg):
            return "BorgBase GraphQL: \(msg)"
        case .unauthenticated:
            return "The BorgBase API token is no longer valid. Paste a new one."
        }
    }
}

struct BorgBaseRepo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let repoPath: String?
    let currentUsage: Double?
    let quota: Double?
    let quotaEnabled: Bool?
    let encryption: String?
    let lastModified: String?
    let createdAt: String?
    let alertDays: Int?
    let region: String?
    let compactionEnabled: Bool?
    let compactionInterval: Int?
    let compactionIntervalUnit: String?
    let compactionHour: Int?
    let compactionHourTimezone: String?
    let fullAccessKeys: [String]?
    let appendOnlyKeys: [String]?
    let rsyncKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, repoPath, currentUsage, quota, quotaEnabled
        case encryption, lastModified, createdAt, alertDays, server
        case compactionEnabled, compactionInterval, compactionIntervalUnit
        case compactionHour, compactionHourTimezone
        case fullAccessKeys, appendOnlyKeys, rsyncKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.repoPath = try? c.decode(String.self, forKey: .repoPath)
        self.currentUsage = try? c.decode(Double.self, forKey: .currentUsage)
        self.quota = try? c.decode(Double.self, forKey: .quota)
        self.quotaEnabled = try? c.decode(Bool.self, forKey: .quotaEnabled)
        self.encryption = try? c.decode(String.self, forKey: .encryption)
        self.lastModified = try? c.decode(String.self, forKey: .lastModified)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        self.alertDays = try? c.decode(Int.self, forKey: .alertDays)
        self.compactionEnabled = try? c.decode(Bool.self, forKey: .compactionEnabled)
        self.compactionInterval = try? c.decode(Int.self, forKey: .compactionInterval)
        self.compactionIntervalUnit = try? c.decode(String.self, forKey: .compactionIntervalUnit)
        self.compactionHour = try? c.decode(Int.self, forKey: .compactionHour)
        self.compactionHourTimezone = try? c.decode(String.self, forKey: .compactionHourTimezone)
        self.fullAccessKeys = try? c.decode([String].self, forKey: .fullAccessKeys)
        self.appendOnlyKeys = try? c.decode([String].self, forKey: .appendOnlyKeys)
        self.rsyncKeys = try? c.decode([String].self, forKey: .rsyncKeys)

        if let serverContainer = try? c.nestedContainer(
            keyedBy: ServerKeys.self, forKey: .server
        ) {
            self.region = try? serverContainer.decode(String.self, forKey: .region)
        } else {
            self.region = nil
        }
    }

    private enum ServerKeys: String, CodingKey {
        case region
    }

    /// Parses BorgBase's `lastModified` ISO-8601 string into a Date.
    /// BorgBase returns timestamps with or without fractional seconds, so
    /// we try the broader formatter first and fall back.
    var lastModifiedDate: Date? {
        guard let s = lastModified, !s.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Some responses omit the timezone; treat as UTC.
        let fallback = DateFormatter()
        fallback.calendar = Calendar(identifier: .iso8601)
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fallback.date(from: s)
    }

    /// True when the repo hasn't been modified within its configured
    /// inactivity alert window. Returns false if either value is missing or
    /// alerts are disabled (`alertDays` is 0 / nil).
    var isStale: Bool {
        guard let days = alertDays, days > 0 else { return false }
        guard let date = lastModifiedDate else { return false }
        let threshold = TimeInterval(days) * 86400
        return Date().timeIntervalSince(date) > threshold
    }
}

struct BorgBaseSSHKey: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let keyType: String?
    let bits: Int?
    let hashMd5: String?
    let addedAt: String?
}

struct BorgBaseAddedKey: Decodable, Hashable {
    let id: String
    let hashMd5: String?
}

struct BorgBaseAddedRepo: Decodable, Hashable {
    let id: String
    let name: String
    let repoPath: String
}

actor BorgBaseClient {
    static let shared = BorgBaseClient()

    private static let endpoint = URL(string: "https://api.borgbase.com/graphql")!

    /// In-memory token cache so we hit the Keychain (and its access prompt
    /// on ad-hoc signed builds) at most once per app session.
    private var cachedToken: String?

    func setToken(_ token: String) {
        cachedToken = token
    }

    func clearToken() {
        cachedToken = nil
    }

    /// Returns true if a token is available (in cache or Keychain). Reads
    /// the Keychain at most once and caches the result.
    func hasToken() -> Bool {
        if cachedToken != nil { return true }
        if let stored = Keychain.borgBaseToken(), !stored.isEmpty {
            cachedToken = stored
            return true
        }
        return false
    }

    private func token() throws -> String {
        if let cached = cachedToken, !cached.isEmpty { return cached }
        guard let stored = Keychain.borgBaseToken(), !stored.isEmpty else {
            throw BorgBaseError.noToken
        }
        cachedToken = stored
        return stored
    }

    func repos() async throws -> [BorgBaseRepo] {
        let query = """
        {
          repoList {
            id
            name
            repoPath
            currentUsage
            quota
            quotaEnabled
            encryption
            lastModified
            createdAt
            alertDays
            compactionEnabled
            compactionInterval
            compactionIntervalUnit
            compactionHour
            compactionHourTimezone
            fullAccessKeys
            appendOnlyKeys
            rsyncKeys
            server { region }
          }
        }
        """
        struct Response: Decodable { let repoList: [BorgBaseRepo] }
        return try await send(query: query, decoding: Response.self).repoList
    }

    func sshKeys() async throws -> [BorgBaseSSHKey] {
        let query = """
        {
          sshList {
            id
            name
            keyType
            bits
            hashMd5
            addedAt
          }
        }
        """
        struct Response: Decodable { let sshList: [BorgBaseSSHKey] }
        return try await send(query: query, decoding: Response.self).sshList
    }

    /// Uploads a new SSH public key to the user's BorgBase account.
    /// `keyData` should be the contents of an `id_*.pub` file (full line,
    /// e.g. `ssh-ed25519 AAAA... comment`). Requires a write-scoped token.
    func addSSHKey(name: String, keyData: String) async throws -> BorgBaseAddedKey {
        let query = """
        mutation sshAdd($name: String!, $keyData: String!) {
          sshAdd(name: $name, keyData: $keyData) {
            keyAdded { id hashMd5 }
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable { let keyAdded: BorgBaseAddedKey }
            let sshAdd: Inner
        }
        let vars: [String: Any] = ["name": name, "keyData": keyData]
        return try await send(query: query, variables: vars, decoding: Wrap.self).sshAdd.keyAdded
    }

    /// Creates a new repository in BorgBase. Requires a write-scoped token.
    /// `fullAccessKeys` is a list of SSH key ids (returned by `addSSHKey`)
    /// that will have full read/write access to the new repo.
    func createRepo(
        name: String,
        fullAccessKeys: [String],
        quotaEnabled: Bool = false,
        region: String = "eu"
    ) async throws -> BorgBaseAddedRepo {
        let query = """
        mutation repoAdd(
          $name: String!,
          $quotaEnabled: Boolean!,
          $fullAccessKeys: [String]!,
          $region: String!
        ) {
          repoAdd(
            name: $name,
            quotaEnabled: $quotaEnabled,
            fullAccessKeys: $fullAccessKeys,
            region: $region
          ) {
            repoAdded { id name repoPath }
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable { let repoAdded: BorgBaseAddedRepo }
            let repoAdd: Inner
        }
        let vars: [String: Any] = [
            "name": name,
            "quotaEnabled": quotaEnabled,
            "fullAccessKeys": fullAccessKeys,
            "region": region,
        ]
        return try await send(query: query, variables: vars, decoding: Wrap.self).repoAdd.repoAdded
    }

    /// Renames a repository. Kept as a convenience wrapper around
    /// `updateRepo` — any caller that only wants to rename doesn't need to
    /// build the full partial-update variables dict.
    func renameRepo(id: String, newName: String) async throws {
        try await updateRepo(id: id, name: newName)
    }

    /// Partial update of a repo on BorgBase. Only the passed (non-nil) fields
    /// are sent to the server, so every other setting is preserved. `quota`
    /// is expected in megabytes, matching what `RepoType.quota` returns.
    func updateRepo(
        id: String,
        name: String? = nil,
        quota: Int? = nil,
        quotaEnabled: Bool? = nil,
        alertDays: Int? = nil,
        compactionEnabled: Bool? = nil,
        compactionInterval: Int? = nil,
        compactionIntervalUnit: String? = nil,
        compactionHour: Int? = nil,
        compactionHourTimezone: String? = nil,
        fullAccessKeys: [String]? = nil,
        appendOnlyKeys: [String]? = nil,
        rsyncKeys: [String]? = nil
    ) async throws {
        var argDecls: [String] = ["$id: String!"]
        var argUses: [String] = ["id: $id"]
        var vars: [String: Any] = ["id": id]

        func addVar<V>(_ key: String, _ value: V?, gqlType: String) {
            guard let value else { return }
            argDecls.append("$\(key): \(gqlType)")
            argUses.append("\(key): $\(key)")
            vars[key] = value
        }

        addVar("name",                   name,                   gqlType: "String")
        addVar("quota",                  quota,                  gqlType: "Int")
        addVar("quotaEnabled",           quotaEnabled,           gqlType: "Boolean")
        addVar("alertDays",              alertDays,              gqlType: "Int")
        addVar("compactionEnabled",      compactionEnabled,      gqlType: "Boolean")
        addVar("compactionInterval",     compactionInterval,     gqlType: "Int")
        addVar("compactionIntervalUnit", compactionIntervalUnit, gqlType: "String")
        addVar("compactionHour",         compactionHour,         gqlType: "Int")
        addVar("compactionHourTimezone", compactionHourTimezone, gqlType: "String")
        addVar("fullAccessKeys",         fullAccessKeys,         gqlType: "[String]")
        addVar("appendOnlyKeys",         appendOnlyKeys,         gqlType: "[String]")
        addVar("rsyncKeys",              rsyncKeys,              gqlType: "[String]")

        // Nothing to change — save a round trip.
        guard argDecls.count > 1 else { return }

        let query = """
        mutation repoEdit(\(argDecls.joined(separator: ", "))) {
          repoEdit(\(argUses.joined(separator: ", "))) {
            __typename
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable {}
            let repoEdit: Inner
        }
        _ = try await send(query: query, variables: vars, decoding: Wrap.self)
    }

    /// Triggers a server-side `borg compact` on the given repo. BorgBase runs
    /// the operation asynchronously in its own infra — we don't get a job id
    /// back, just a success envelope. Useful because compaction over SSH on a
    /// large repo can saturate the user's uplink for hours, but here it's a
    /// one-shot fire-and-forget.
    func compactRepo(id: String) async throws {
        let query = """
        mutation repoCompact($id: String!) {
          repoCompact(id: $id) {
            __typename
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable {}
            let repoCompact: Inner
        }
        _ = try await send(query: query, variables: ["id": id], decoding: Wrap.self)
    }

    /// Deletes a repository permanently. BorgBase requires the account to be
    /// in good standing and the caller token to have write scope. There is no
    /// undo — the repo's data is erased server-side.
    func deleteRepo(id: String) async throws {
        let query = """
        mutation repoDelete($id: String!) {
          repoDelete(id: $id) {
            __typename
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable {}
            let repoDelete: Inner
        }
        _ = try await send(query: query, variables: ["id": id], decoding: Wrap.self)
    }

    /// Deletes an SSH public key from the user's BorgBase account. Any repo
    /// whose ACL referenced only this key will become unreachable.
    func deleteSSHKey(id: String) async throws {
        let query = """
        mutation sshDelete($id: String!) {
          sshDelete(id: $id) {
            __typename
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable {}
            let sshDelete: Inner
        }
        _ = try await send(query: query, variables: ["id": id], decoding: Wrap.self)
    }

    // MARK: - HTTP plumbing

    private func send<T: Decodable>(
        query: String,
        variables: [String: Any]? = nil,
        decoding: T.Type
    ) async throws -> T {
        let token = try self.token()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["query": query]
        if let variables {
            body["variables"] = variables
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BorgBaseError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            cachedToken = nil
            throw BorgBaseError.unauthenticated
        }
        if http.statusCode != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw BorgBaseError.http(http.statusCode, String(snippet.prefix(400)))
        }

        let envelope = try JSONDecoder().decode(GraphQLEnvelope<T>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            let joined = errors.map(\.message).joined(separator: "; ")
            let lower = joined.lowercased()
            // BorgBase returns 200 even on auth failures and reports the
            // problem as a GraphQL error — detect it so the wizard can bounce
            // the user back to the token entry screen.
            if lower.contains("not authenticated") || lower.contains("unauthorized") {
                cachedToken = nil
                throw BorgBaseError.unauthenticated
            }
            throw BorgBaseError.graphql(joined)
        }
        guard let payload = envelope.data else {
            throw BorgBaseError.invalidResponse
        }
        return payload
    }
}

private struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorEntry]?
}

private struct GraphQLErrorEntry: Decodable {
    let message: String
}
