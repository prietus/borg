import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: RepositoryStore
    @EnvironmentObject var borgBoxStore: BorgBoxServerStore
    @EnvironmentObject var statusStore: BackupRunStatusStore
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Repository.ID?
    @State private var addIntent: AddRepoIntent?
    @State private var showingBorgBase = false
    @State private var showingBorgBox = false
    @State private var showingStats = false
    @State private var showingAutomation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selection,
               let repo = store.repositories.first(where: { $0.id == id }) {
                RepositoryDetailView(repository: repo)
                    .id(repo.id)
            } else {
                ContentUnavailableView(
                    "Select a repository",
                    systemImage: "externaldrive",
                    description: Text("Add or pick a repository in the sidebar.")
                )
            }
        }
        .sheet(item: $addIntent) { intent in
            AddRepositorySheet(initialName: intent.name, initialUrl: intent.url)
        }
        .sheet(isPresented: $showingBorgBase) {
            BorgBaseSheet { name, url in
                showingBorgBase = false
                addIntent = AddRepoIntent(name: name, url: url)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showingBorgBox) {
            BorgBoxServerPanel()
                .environmentObject(borgBoxStore)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingStats) {
            StatsPanel()
                .environmentObject(store)
                .environmentObject(borgBoxStore)
                .environmentObject(statusStore)
        }
        .sheet(isPresented: $showingAutomation) {
            AutomationPanel()
                .environmentObject(borgBoxStore)
        }
        .onChange(of: store.pendingSelection) { _, newValue in
            if let id = newValue {
                selection = id
                store.pendingSelection = nil
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Repositories") {
                ForEach(store.repositories) { repo in
                    Label(repo.name, systemImage: "externaldrive.fill")
                        .tag(Optional(repo.id))
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                if selection == repo.id { selection = nil }
                                store.remove(repo)
                            }
                        }
                }
            }
        }
        .navigationTitle("BorgMac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        openWindow(id: "wizard")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("New on BorgBase…", systemImage: "wand.and.stars")
                    }
                    Button {
                        openWindow(id: "borgbox-wizard")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("New on BorgBox…", systemImage: "server.rack")
                    }
                    Button {
                        openWindow(id: "borg-wizard")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("New Borg repository (local or SSH)…", systemImage: "wand.and.stars.inverse")
                    }
                    Divider()
                    Button {
                        addIntent = AddRepoIntent(name: "", url: "")
                    } label: {
                        Label("Add existing repository…", systemImage: "plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a repository")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingBorgBase = true
                } label: {
                    Label("BorgBase", systemImage: "cloud")
                }
                .help("Open BorgBase panel (remote repos and SSH keys)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingBorgBox = true
                } label: {
                    Label("BorgBox", systemImage: "server.rack")
                }
                .help("Open BorgBox server panel (stats, repos, maintenance)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingStats = true
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                .help("Aggregated statistics panel across all repositories")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAutomation = true
                } label: {
                    Label("Automation", systemImage: "clock.arrow.circlepath")
                }
                .help("Manage BorgBox maintenance schedules across all servers")
            }
        }
        .frame(minWidth: 220)
    }
}

struct AddRepoIntent: Identifiable {
    let id = UUID()
    let name: String
    let url: String
}
