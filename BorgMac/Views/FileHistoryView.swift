import SwiftUI
import QuickLook

struct FileHistoryView: View {
    let repository: Repository
    let filePath: String

    @Environment(\.dismiss) private var dismiss

    @State private var archives: [Archive] = []
    @State private var versions: [FileVersion] = []
    @State private var loadingArchives = false
    @State private var indexing = false
    @State private var indexProgress: Int = 0
    @State private var indexTotal: Int = 0
    @State private var previewURL: URL?
    @State private var previewLoading = false
    @State private var error: String?
    @State private var selection: String?

    struct FileVersion: Identifiable, Hashable {
        let archiveName: String
        let archiveId: String
        let archiveStart: String
        let entry: ArchiveEntry?
        let indexed: Bool

        var id: String { archiveId }
        var exists: Bool { entry != nil }
    }

    private var indexedCount: Int {
        versions.filter { $0.indexed }.count
    }

    private var notIndexedCount: Int {
        versions.filter { !$0.indexed }.count
    }

    private var presentCount: Int {
        versions.filter { $0.exists }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await loadArchives() }
        .quickLookPreview($previewURL)
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File history")
                        .font(.title3.bold())
                    Text(filePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loadingArchives {
            VStack(spacing: 6) {
                ProgressView("Listing the repository's archives…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            ContentUnavailableView(
                "No archives",
                systemImage: "tray",
                description: Text("The repository has no archives.")
            )
        } else {
            table
        }
    }

    private var table: some View {
        Table(versions, selection: $selection) {
            TableColumn("Archive") { v in
                HStack(spacing: 6) {
                    Image(systemName: statusIcon(for: v))
                        .foregroundStyle(statusColor(for: v))
                    Text(v.archiveName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Date") { v in
                Text(formatDate(v.archiveStart))
                    .font(.caption.monospacedDigit())
            }
            TableColumn("Size") { v in
                if let entry = v.entry {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(entry.sizeBytes),
                        countStyle: .file
                    ))
                    .font(.caption.monospacedDigit())
                } else if !v.indexed {
                    Text("—")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("missing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            TableColumn("Status") { v in
                Text(statusText(for: v))
                    .font(.caption)
                    .foregroundStyle(statusColor(for: v))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let v = versions.first(where: { $0.id == id }), v.exists {
                Button("Preview") { Task { await preview(v) } }
                Button("Save as…") { saveAs(v) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let v = versions.first(where: { $0.id == id }), v.exists {
                Task { await preview(v) }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if indexing {
                ProgressView(value: Double(indexProgress), total: Double(max(indexTotal, 1)))
                    .frame(width: 160)
                Text("Indexing \(indexProgress)/\(indexTotal)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("\(presentCount) present", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                if notIndexedCount > 0 {
                    Label("\(notIndexedCount) not indexed", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Spacer()

            if previewLoading {
                ProgressView().controlSize(.small)
            }

            if notIndexedCount > 0 {
                Button {
                    Task { await indexMissing() }
                } label: {
                    Label("Index missing", systemImage: "square.and.arrow.down")
                }
                .disabled(indexing)
                .help("Downloads the manifests of archives that aren't indexed yet to complete the history. Each one costs one borg call.")
            }
        }
        .padding(14)
    }

    // MARK: - Loading

    private func loadArchives() async {
        loadingArchives = true
        defer { loadingArchives = false }
        do {
            let list = try await BorgClient.shared.listArchives(repo: repository)
            archives = list.sorted { $0.start > $1.start }
            rebuildVersions()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuildVersions() {
        var result: [FileVersion] = []
        for archive in archives {
            if let cached = ArchiveCache.load(archiveId: archive.archiveId) {
                let entry = cached.first(where: { $0.path == filePath })
                result.append(FileVersion(
                    archiveName: archive.name,
                    archiveId: archive.archiveId,
                    archiveStart: archive.start,
                    entry: entry,
                    indexed: true
                ))
            } else {
                result.append(FileVersion(
                    archiveName: archive.name,
                    archiveId: archive.archiveId,
                    archiveStart: archive.start,
                    entry: nil,
                    indexed: false
                ))
            }
        }
        versions = result
    }

    private func indexMissing() async {
        let targets = archives.filter { archive in
            ArchiveCache.load(archiveId: archive.archiveId) == nil
        }
        guard !targets.isEmpty else { return }
        indexing = true
        indexProgress = 0
        indexTotal = targets.count
        defer { indexing = false }

        for archive in targets {
            do {
                let entries = try await BorgClient.shared.listArchiveEntries(
                    repo: repository,
                    archive: archive.name
                )
                ArchiveCache.save(archiveId: archive.archiveId, entries: entries)
            } catch {
                self.error = error.localizedDescription
                break
            }
            indexProgress += 1
            rebuildVersions()
        }
    }

    // MARK: - Actions

    private func preview(_ version: FileVersion) async {
        guard let entry = version.entry, !entry.isDirectory else { return }
        previewLoading = true
        defer { previewLoading = false }
        do {
            let url = try await BorgClient.shared.extractToTemp(
                repo: repository,
                archive: version.archiveName,
                entryPath: entry.path
            )
            previewURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveAs(_ version: FileVersion) {
        guard let entry = version.entry, !entry.isDirectory else { return }
        let panel = NSSavePanel()
        let suggestedName = entry.name
        panel.nameFieldStringValue = "\(suggestedName).\(version.archiveName)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let tmp = try await BorgClient.shared.extractToTemp(
                    repo: repository,
                    archive: version.archiveName,
                    entryPath: entry.path
                )
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func statusIcon(for v: FileVersion) -> String {
        if !v.indexed { return "questionmark.circle" }
        return v.exists ? "checkmark.circle.fill" : "minus.circle"
    }

    private func statusColor(for v: FileVersion) -> Color {
        if !v.indexed { return .orange }
        return v.exists ? .green : .secondary
    }

    private func statusText(for v: FileVersion) -> String {
        if !v.indexed { return "not indexed" }
        return v.exists ? "present" : "missing"
    }

    private func formatDate(_ raw: String) -> String {
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
