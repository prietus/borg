import Foundation

/// A registered BorgBox server (self-hosted REST daemon that manages borg repos).
struct BorgBoxServer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String         // user-facing label, e.g. "Home NAS"
    var daemonURL: String    // http://hive.local:9999 (no /api/v1 suffix)
    var sshHost: String      // hive.local
    var sshUser: String      // borg
    var sshPort: Int         // 22
}
