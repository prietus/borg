import SwiftUI
import AppKit

struct CreateBackupSheet: View {
    let repository: Repository
    var onCompleted: () -> Void

    @EnvironmentObject var manualBackupStore: ManualBackupStore
    @Environment(\.dismiss) private var dismiss
    @State private var archiveName: String = CreateBackupSheet.defaultArchiveName()
    @State private var paths: [URL] = []
    @State private var excludes: [String] = []
    @State private var newExcludePattern: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New backup")
                .font(.title2.bold())

            Form {
                TextField("Archive name", text: $archiveName)

                Section("Paths to back up") {
                    if paths.isEmpty {
                        Text("No paths selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(paths, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder")
                                Text(url.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    paths.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button {
                        addPath()
                    } label: {
                        Label("Add path", systemImage: "plus")
                    }
                }

                Section("Exclude") {
                    if excludes.isEmpty {
                        Text("No exclusion patterns.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(excludes.enumerated()), id: \.offset) { idx, pattern in
                            HStack {
                                Image(systemName: "nosign")
                                Text(pattern)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    excludes.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    TextField("Pattern (e.g. **/node_modules)", text: $newExcludePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitNewExclude() }
                    HStack {
                        Button("Add") { commitNewExclude() }
                            .disabled(newExcludePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Button("Add common presets") { addPresetExcludes() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start backup") { runBackup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(paths.isEmpty || archiveName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 460)
    }

    private func commitNewExclude() {
        let trimmed = newExcludePattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !excludes.contains(trimmed) {
            excludes.append(trimmed)
        }
        newExcludePattern = ""
    }

    private func addPresetExcludes() {
        for preset in BackupSchedule.commonExcludePresets where !excludes.contains(preset) {
            excludes.append(preset)
        }
    }

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !paths.contains(url) {
                paths.append(url)
            }
        }
    }

    private func runBackup() {
        // Hand the job off to ManualBackupStore so it can keep running after
        // this sheet closes. Visibility moves to the menu bar drawer.
        manualBackupStore.start(
            repo: repository,
            archiveName: archiveName,
            paths: paths.map { $0.path },
            excludes: excludes,
            onCompleted: onCompleted
        )
        dismiss()
    }

    private static func defaultArchiveName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let host = Host.current().localizedName ?? "mac"
        return "manual-\(host)-\(fmt.string(from: Date()))"
    }
}
