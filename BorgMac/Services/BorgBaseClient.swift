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
    let alertDays: Int?
    let region: String?

    enum CodingKeys: String, CodingKey {
        case id, name, repoPath, currentUsage, quota, quotaEnabled
        case encryption, lastModified, alertDays, server
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
        self.alertDays = try? c.decode(Int.self, forKey: .alertDays)

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
            alertDays
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

    /// Renames a repository. `repoEdit` accepts many optional fields; we
    /// only send `id` and `name` so every other setting (quota, region,
    /// keys…) is left untouched server-side.
    func renameRepo(id: String, newName: String) async throws {
        let query = """
        mutation repoEdit($id: String!, $name: String!) {
          repoEdit(id: $id, name: $name) {
            __typename
          }
        }
        """
        struct Wrap: Decodable {
            struct Inner: Decodable {}
            let repoEdit: Inner
        }
        _ = try await send(
            query: query,
            variables: ["id": id, "name": newName],
            decoding: Wrap.self
        )
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
