import Foundation

struct Repository: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    /// Optional path to a private SSH key dedicated to this repository.
    /// When set, BorgClient passes it to borg via BORG_RSH so each repo uses
    /// its own key without touching the user's ~/.ssh/config.
    var sshKeyPath: String? = nil
    /// Zero or more launchd-backed backup schedules. Each one gets its own
    /// plist at `~/Library/LaunchAgents/com.carlos.BorgMac.backup.<repoUUID>.<scheduleUUID>.plist`.
    var schedules: [BackupSchedule] = []

    enum CodingKeys: String, CodingKey {
        case id, name, url, sshKeyPath, schedules
        /// Legacy single-schedule key from the pre-multi-job layout.
        case schedule
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        sshKeyPath: String? = nil,
        schedules: [BackupSchedule] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.sshKeyPath = sshKeyPath
        self.schedules = schedules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(UUID.self,   forKey: .id) ?? UUID()
        name       = try c.decode(String.self, forKey: .name)
        url        = try c.decode(String.self, forKey: .url)
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)

        if let arr = try c.decodeIfPresent([BackupSchedule].self, forKey: .schedules) {
            schedules = arr
        } else if let legacy = try c.decodeIfPresent(BackupSchedule.self, forKey: .schedule) {
            // Pre-multi-job format: wrap the single schedule in an array.
            // Its id was generated on decode because the old layout didn't
            // persist one. RepositoryStore.migrateLegacySchedulesIfNeeded()
            // picks this up and reinstalls the plist under the new label.
            schedules = [legacy]
        } else {
            schedules = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,         forKey: .id)
        try c.encode(name,       forKey: .name)
        try c.encode(url,        forKey: .url)
        try c.encodeIfPresent(sshKeyPath, forKey: .sshKeyPath)
        try c.encode(schedules,  forKey: .schedules)
        // Deliberately do not write `.schedule` — the legacy key is read-only.
    }
}

struct Archive: Identifiable, Decodable, Hashable {
    var id: String { name }
    let name: String
    let archiveId: String
    let start: String

    enum CodingKeys: String, CodingKey {
        case name
        case archiveId = "id"
        case start
    }
}

struct ArchiveListResponse: Decodable {
    let archives: [Archive]
}

/// Decodes `borg info --json <repo>`. We only pull the fields the stats
/// panel actually uses — the full JSON has more (cache id, security dir,
/// last modified, etc.) that the app doesn't need.
struct BorgRepoInfo: Decodable {
    let repository: RepoBlock
    let cache: CacheBlock
    let archiveCount: Int

    struct RepoBlock: Decodable {
        let id: String
        let location: String
        let lastModified: String?

        enum CodingKeys: String, CodingKey {
            case id, location
            case lastModified = "last_modified"
        }
    }

    struct CacheBlock: Decodable {
        let stats: Stats

        struct Stats: Decodable {
            /// Sum of original file sizes across all archives.
            let totalSize: Int64
            /// Sum after compression.
            let totalCsize: Int64
            /// Bytes actually stored after dedup. This is the one that
            /// matters for "how much disk is this repo using".
            let uniqueCsize: Int64
            /// Number of chunks referenced at least once.
            let totalUniqueChunks: Int64?
            let totalChunks: Int64?

            enum CodingKeys: String, CodingKey {
                case totalSize         = "total_size"
                case totalCsize        = "total_csize"
                case uniqueCsize       = "unique_csize"
                case totalUniqueChunks = "total_unique_chunks"
                case totalChunks       = "total_chunks"
            }
        }
    }

    /// `borg info --json` returns `archives: [...]` at the top level; we
    /// just count them so the stats panel can show "N archives" without
    /// holding the full payload.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RawKeys.self)
        self.repository = try c.decode(RepoBlock.self, forKey: .repository)
        self.cache = try c.decode(CacheBlock.self, forKey: .cache)
        if let archives = try? c.decode([ArchiveStub].self, forKey: .archives) {
            self.archiveCount = archives.count
        } else {
            self.archiveCount = 0
        }
    }

    private enum RawKeys: String, CodingKey {
        case repository, cache, archives
    }

    private struct ArchiveStub: Decodable {}
}
