import SwiftUI
import QuickLook

struct ArchiveBrowserView: View {
    let repository: Repository
    let archive: Archive

    @Environment(\.dismiss) private var dismiss

    @State private var root: ArchiveTree?
    @State private var path: [String] = []
    @State private var loading = false
    @State private var previewLoading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var selection: String?
    @State private var historyPath: String?
    @State private var searchQuery: String = ""

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let maxSearchResults = 500

    private var currentNode: ArchiveTree? {
        root?.node(at: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { await load() }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(
            get: { historyPath.map(HistoryPath.init) },
            set: { historyPath = $0?.value }
        )) { wrapper in
            FileHistoryView(repository: repository, filePath: wrapper.value)
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
    }

    private struct HistoryPath: Identifiable {
        let value: String
        var id: String { value }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")

            Divider().frame(height: 16)

            Button {
                if !path.isEmpty { path.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(path.isEmpty)
            .help("Back")

            Button {
                path.removeAll()
            } label: {
                Image(systemName: "house")
            }
            .disabled(path.isEmpty)
            .help("Root")

            Divider().frame(height: 16)

            Text(archive.name)
                .font(.headline)
            Text("/")
                .foregroundStyle(.tertiary)
            Text(path.isEmpty ? "root" : path.joined(separator: " / "))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let node = currentNode {
                Text("\(node.children.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if previewLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the whole archive (name or path)…", text: $searchQuery)
                .textFieldStyle(.plain)
            if isSearching {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                Text("\(searchResults.count)\(searchResults.count >= Self.maxSearchResults ? "+" : "") results")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Search

    /// Walks the entire tree once per query — fine because the tree is in
    /// memory and queries are user-typed (low frequency).
    private var searchResults: [ArchiveTree] {
        guard let root else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var results: [ArchiveTree] = []
        results.reserveCapacity(64)
        func walk(_ node: ArchiveTree) {
            if results.count >= Self.maxSearchResults { return }
            // Skip the synthetic root (empty path) but visit its children.
            if !node.path.isEmpty {
                if node.name.lowercased().contains(q)
                    || node.path.lowercased().contains(q) {
                    results.append(node)
                }
            }
            for child in node.children {
                if results.count >= Self.maxSearchResults { return }
                walk(child)
            }
        }
        walk(root)
        return results
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 8) {
                ProgressView("Loading archive index…")
                Text("The first time takes a while depending on size. Subsequent loads are instant (on-disk cache).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            searchResultsList
        } else if let node = currentNode {
            if node.children.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text("No entries at this path.")
                )
            } else {
                fileList(node: node)
            }
        } else {
            ContentUnavailableView(
                "No data",
                systemImage: "questionmark.folder",
                description: Text("Could not load the index.")
            )
        }
    }

    private var searchResultsList: some View {
        let results = searchResults
        return Group {
            if results.isEmpty {
                ContentUnavailableView(
                    "No results",
                    systemImage: "magnifyingglass",
                    description: Text("No file or folder matches \"\(searchQuery)\".")
                )
            } else {
                List(selection: $selection) {
                    ForEach(results, id: \.path) { node in
                        searchRow(for: node)
                            .tag(Optional(node.path))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { revealInBrowser(node) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let node = results.first(where: { $0.path == id }) {
                        if node.isDirectory {
                            Button("Go to folder") { revealInBrowser(node) }
                        } else {
                            Button("Preview") { Task { await preview(node) } }
                            Button("Go to parent folder") { revealInBrowser(node) }
                            Button("History…") { historyPath = node.path }
                            Button("Save as…") { saveAs(node) }
                        }
                    }
                }
            }
        }
    }

    private func searchRow(for node: ArchiveTree) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: node))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if !node.isDirectory {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(node.entry?.sizeBytes ?? 0),
                    countStyle: .file
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Navigates the file browser to the parent folder of the given search
    /// hit and clears the search query so the user sees the file in context.
    private func revealInBrowser(_ node: ArchiveTree) {
        let parts = node.path.split(separator: "/").map(String.init)
        if node.isDirectory {
            path = parts
        } else {
            // Drop the filename so we land in the parent.
            path = parts.dropLast()
            selection = node.path
        }
        searchQuery = ""
    }

    private func fileList(node: ArchiveTree) -> some View {
        List(selection: $selection) {
            ForEach(node.children, id: \.path) { child in
                row(for: child)
                    .tag(Optional(child.path))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { activate(child) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let child = node.childrenByName.values.first(where: { $0.path == id }) {
                if child.isDirectory {
                    Button("Open") { activate(child) }
                } else {
                    Button("Preview") { Task { await preview(child) } }
                    Button("History…") { historyPath = child.path }
                    Button("Save as…") { saveAs(child) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for node: ArchiveTree) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: node))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !node.isDirectory {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(node.entry?.sizeBytes ?? 0),
                    countStyle: .file
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(formatMtime(node.entry?.mtime ?? ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for node: ArchiveTree) -> String {
        if node.isDirectory { return "folder.fill" }
        if node.entry?.isSymlink == true { return "arrow.turn.up.right" }
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "bmp", "webp":
            return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "m4a", "wav", "flac", "aac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "log":
            return "doc.text"
        case "swift", "py", "rb", "js", "ts", "go", "rs", "c", "cpp", "h", "json", "yaml", "yml", "toml":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "bz2", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    // MARK: - Actions

    private func activate(_ node: ArchiveTree) {
        if node.isDirectory {
            path.append(node.name)
        } else {
            Task { await preview(node) }
        }
    }

    private func preview(_ node: ArchiveTree) async {
        guard let entry = node.entry, !node.isDirectory else { return }
        previewLoading = true
        defer { previewLoading = false }
        do {
            let url = try await BorgClient.shared.extractToTemp(
                repo: repository,
                archive: archive.name,
                entryPath: entry.path
            )
            previewURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveAs(_ node: ArchiveTree) {
        guard let entry = node.entry, !node.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let tmp = try await BorgClient.shared.extractToTemp(
                    repo: repository,
                    archive: archive.name,
                    entryPath: entry.path
                )
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard root == nil else { return }
        loading = true
        defer { loading = false }

        if let cached = ArchiveCache.load(archiveId: archive.archiveId) {
            root = ArchiveTree.build(from: cached)
            return
        }

        do {
            let entries = try await BorgClient.shared.listArchiveEntries(
                repo: repository,
                archive: archive.name
            )
            ArchiveCache.save(archiveId: archive.archiveId, entries: entries)
            root = ArchiveTree.build(from: entries)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private func formatMtime(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        var date = input.date(from: raw)
        if date == nil {
            input.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            date = input.date(from: raw)
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return out.string(from: date)
    }
}
