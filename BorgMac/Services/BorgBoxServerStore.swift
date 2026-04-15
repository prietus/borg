import Foundation

@MainActor
final class BorgBoxServerStore: ObservableObject {
    @Published private(set) var servers: [BorgBoxServer] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BorgMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("borgbox_servers.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BorgBoxServer].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL)
    }

    func add(_ server: BorgBoxServer, token: String) throws {
        try Keychain.setBorgBoxToken(token, for: server.id)
        servers.append(server)
        persist()
    }

    func remove(_ server: BorgBoxServer) {
        servers.removeAll { $0.id == server.id }
        Keychain.deleteBorgBoxToken(for: server.id)
        persist()
    }

    /// For v1 we act on the "current" (first) server. Multi-server selection
    /// can be added later without changing the storage format.
    var first: BorgBoxServer? { servers.first }
}
