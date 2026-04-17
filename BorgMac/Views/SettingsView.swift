import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LicensePane()
                .tabItem {
                    Label("License", systemImage: "key.fill")
                }
        }
        .frame(width: 520, height: 360)
    }
}

struct LicensePane: View {
    @EnvironmentObject var license: LicenseManager
    @State private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            GroupBox {
                statusBlock
                    .padding(.vertical, 4)
            }

            if !license.status.isPaid {
                GroupBox("Activate a license") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter the license key you received by email from LemonSqueezy.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $keyInput)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .onSubmit { activate() }

                            Button {
                                activate()
                            } label: {
                                if license.isBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Activate")
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(license.isBusy || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        HStack(spacing: 14) {
                            Button {
                                license.openCheckout()
                            } label: {
                                Label("Buy a license", systemImage: "cart.fill")
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        if let err = license.lastError {
                            Text(err)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if license.status.isPaid {
                Button(role: .destructive) {
                    Task { await license.deactivate() }
                } label: {
                    Label("Deactivate this Mac", systemImage: "key.slash")
                }
            }

            Spacer()

            #if DEBUG
            debugControls
            #endif
        }
        .padding(22)
    }

    #if DEBUG
    private var debugControls: some View {
        GroupBox("Debug (not shipped)") {
            HStack(spacing: 10) {
                Button("Force expired") {
                    license.debugForceExpired()
                }
                Button("Reset trial (14d)") {
                    license.debugResetTrial()
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("BorgMac")
                    .font(.title2.weight(.semibold))
                Text("Native Borg backup client for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch license.status {
        case .unknown:
            Label("Checking license…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        case .trial(let days):
            Label {
                Text("Trial · \(days) day\(days == 1 ? "" : "s") remaining")
            } icon: {
                Image(systemName: "clock.badge").foregroundStyle(.yellow)
            }
        case .expired:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trial expired").font(.body.weight(.semibold))
                    Text("Adding new repositories, schedules and servers is disabled. Existing ones keep running — buy a license to unlock creation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        case .licensed(let email):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Licensed").font(.body.weight(.semibold))
                    Text(email).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
    }

    private func activate() {
        let key = keyInput
        Task {
            await license.activate(key: key)
            if license.status.isPaid {
                keyInput = ""
            }
        }
    }
}
