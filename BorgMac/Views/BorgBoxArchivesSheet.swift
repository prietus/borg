import SwiftUI

struct BorgBoxArchivesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: BorgBoxServer
    let repo: String
    let passphrase: String?

    @State private var archives: [BorgBoxRemoteArchive] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selection: BorgBoxRemoteArchive.ID?
    @State private var search: String = ""

    private var filtered: [BorgBoxRemoteArchive] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return archives }
        return archives.filter { archive in
            archive.name.lowercased().contains(q)
                || (archive.hostname?.lowercased().contains(q) ?? false)
                || (archive.username?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading && archives.isEmpty {
                ProgressView("Loading archives…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if archives.isEmpty, let error {
                errorState(error)
            } else if archives.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(width: 880, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archives").font(.title3.bold())
                Text(repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Name") { archive in
                Text(archive.name)
                    .font(.body.monospaced())
                    .help(archive.name)
            }
            .width(min: 300, ideal: 360)

            TableColumn("Date") { archive in
                Text(formatDate(archive.time))
            }
            .width(min: 150, ideal: 170)

            TableColumn("Host") { archive in
                Text(archive.hostname ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("User") { archive in
                Text(archive.username ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Comment") { archive in
                Text(archive.comment?.isEmpty == false ? (archive.comment ?? "") : "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 100, ideal: 200)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No archives")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This repo doesn't have any backups yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text("Error loading archives")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(filtered.count) archive\(filtered.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            let result = try await BorgBoxClient.shared.remoteArchives(
                server: server,
                repo: repo,
                passphrase: passphrase
            )
            archives = result.sorted { ($0.time ?? "") > ($1.time ?? "") }
        } catch BorgBoxError.http(404, _) {
            error = "The daemon doesn't implement /repos/\(repo)/archives yet, or the repo isn't initialized."
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func formatDate(_ raw: String?) -> String {
        guard let raw else { return "—" }
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = input.date(from: raw)
        if date == nil {
            input.formatOptions = [.withInternetDateTime]
            date = input.date(from: raw)
        }
        if date == nil {
            // Borg sometimes emits "yyyy-MM-dd'T'HH:mm:ss.SSSSSS" without TZ.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            date = df.date(from: raw)
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}
