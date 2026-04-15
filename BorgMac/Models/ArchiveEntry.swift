import Foundation

/// A single entry inside a Borg archive, as returned by `borg list --json-lines`.
struct ArchiveEntry: Codable, Hashable {
    let type: String
    let path: String
    let size: UInt64?
    let mtime: String?

    var isDirectory: Bool { type == "d" }
    var isSymlink: Bool { type == "l" }
    var sizeBytes: UInt64 { size ?? 0 }
    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// In-memory tree view over a flat list of archive entries.
/// Built once per archive load; not observed — callers assign the root to @State
/// and re-read. Never mutated after construction.
final class ArchiveTree {
    let name: String
    let path: String
    let entry: ArchiveEntry?
    private(set) var children: [ArchiveTree] = []
    private(set) var childrenByName: [String: ArchiveTree] = [:]

    init(name: String, path: String, entry: ArchiveEntry?) {
        self.name = name
        self.path = path
        self.entry = entry
    }

    var isDirectory: Bool {
        entry?.isDirectory ?? true  // synthetic intermediate nodes act as dirs
    }

    /// Total size of this subtree in bytes. Computed lazily on first access
    /// and cached afterwards; safe because ArchiveTree is immutable post-build.
    private var _totalSize: UInt64?
    var totalSize: UInt64 {
        if let cached = _totalSize { return cached }
        let own = entry?.sizeBytes ?? 0
        let childSum = children.reduce(UInt64(0)) { $0 + $1.totalSize }
        let total = own + childSum
        _totalSize = total
        return total
    }

    static func build(from entries: [ArchiveEntry]) -> ArchiveTree {
        let root = ArchiveTree(name: "/", path: "", entry: nil)
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let isLast = (i == parts.count - 1)
                if let child = node.childrenByName[part] {
                    if isLast, child.entry == nil {
                        // Replace synthetic node with real entry
                        let replacement = ArchiveTree(
                            name: part,
                            path: child.path,
                            entry: entry
                        )
                        replacement.children = child.children
                        replacement.childrenByName = child.childrenByName
                        if let idx = node.children.firstIndex(where: { $0 === child }) {
                            node.children[idx] = replacement
                        }
                        node.childrenByName[part] = replacement
                        node = replacement
                    } else {
                        node = child
                    }
                } else {
                    let childPath = parts[0...i].joined(separator: "/")
                    let child = ArchiveTree(
                        name: part,
                        path: childPath,
                        entry: isLast ? entry : nil
                    )
                    node.children.append(child)
                    node.childrenByName[part] = child
                    node = child
                }
            }
        }
        root.sortRecursively()
        return root
    }

    private func sortRecursively() {
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in children {
            child.sortRecursively()
        }
    }

    func node(at path: [String]) -> ArchiveTree {
        var current = self
        for segment in path {
            if let next = current.childrenByName[segment] {
                current = next
            } else {
                break
            }
        }
        return current
    }
}

/// On-disk cache of archive file listings, keyed by the archive's Borg id.
/// Archive ids are immutable, so cached entries never need invalidation.
enum ArchiveCache {
    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("BorgMac", isDirectory: true)
            .appendingPathComponent("archives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(archiveId: String) -> [ArchiveEntry]? {
        let url = directory.appendingPathComponent("\(archiveId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ArchiveEntry].self, from: data)
    }

    static func save(archiveId: String, entries: [ArchiveEntry]) {
        let url = directory.appendingPathComponent("\(archiveId).json")
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url)
    }
}
