import SwiftUI

/// Edit sheet for a BorgBase repository. Covers "General" (name, quota,
/// inactivity alert) and "Compaction" (server-side scheduled compaction).
/// ACLs, activity log and usage history will be layered on in later passes.
///
/// Only fields the user actually changed are sent to the API (the partial
/// `updateRepo` helper in `BorgBaseClient`), so nothing else on the repo is
/// clobbered by a blind rewrite.
struct BorgBaseEditRepoSheet: View {
    let repo: BorgBaseRepo
    let accountKeys: [BorgBaseSSHKey]
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var quotaEnabled: Bool = false
    /// Quota expressed in GB for the UI. We store GB instead of MB so the
    /// number the user types matches what the BorgBase dashboard shows. It's
    /// converted back to MB (×1000) right before sending to the API.
    @State private var quotaGB: String = ""
    @State private var alertDays: Int = 0

    // Scheduled compaction. The interval unit is a free-form string on the
    // BorgBase side — we offer the three common buckets (day/week/month) and
    // preserve any exotic value the server reports unchanged.
    @State private var compactionEnabled: Bool = false
    @State private var compactionInterval: Int = 1
    @State private var compactionUnit: CompactionUnit = .week
    @State private var compactionHour: Int = 3
    @State private var compactionTimezone: String = TimeZone.current.identifier

    /// Per-key access choice. BorgBase stores three disjoint id lists on the
    /// repo; in the UI we collapse them into one pick-per-key because a key
    /// can never appear in more than one list at a time anyway.
    @State private var accessByKey: [String: AccessLevel] = [:]

    @State private var saving = false
    @State private var error: String?

    enum CompactionUnit: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day:   return "day(s)"
            case .week:  return "week(s)"
            case .month: return "month(s)"
            }
        }
    }

    enum AccessLevel: String, CaseIterable, Identifiable {
        case none, full, appendOnly, rsync
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:       return "No access"
            case .full:       return "Full"
            case .appendOnly: return "Append-only"
            case .rsync:      return "Rsync"
            }
        }
        var tint: Color {
            switch self {
            case .none:       return .secondary
            case .full:       return .accentColor
            case .appendOnly: return .green
            case .rsync:      return .orange
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                        .disabled(saving)
                    if let createdAt = formattedCreatedAt {
                        LabeledContent("Created") {
                            Text(createdAt).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Repository ID") {
                        Text(repo.id)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Quota") {
                    Toggle("Enforce quota", isOn: $quotaEnabled)
                        .disabled(saving)
                    if quotaEnabled {
                        HStack {
                            TextField("Limit", text: $quotaGB)
                                .disabled(saving)
                                .frame(maxWidth: 120)
                            Text("GB").foregroundStyle(.secondary)
                        }
                        Text("BorgBase will reject writes that push the repo past this limit. Leave the toggle off for unlimited usage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Inactivity alert") {
                    Stepper(value: $alertDays, in: 0...365) {
                        if alertDays == 0 {
                            Text("Alerts disabled").foregroundStyle(.secondary)
                        } else {
                            Text("Alert after \(alertDays) day\(alertDays == 1 ? "" : "s") with no activity")
                        }
                    }
                    .disabled(saving)
                    Text("BorgBase emails you if the repo hasn't received a backup within this window. Set to 0 to turn it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Access control") {
                    if accountKeys.isEmpty {
                        Text("No SSH keys on this BorgBase account. Add one from the SSH Keys tab first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(accountKeys) { key in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.name).font(.callout)
                                    if let fp = key.hashMd5, !fp.isEmpty {
                                        Text(fp)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { accessByKey[key.id] ?? .none },
                                    set: { accessByKey[key.id] = $0 }
                                )) {
                                    ForEach(AccessLevel.allCases) { level in
                                        Text(level.label).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 160)
                            }
                            .disabled(saving)
                        }

                        Text("Full: read & write. Append-only: backups yes, delete/modify no. Rsync: legacy rsync-only access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Scheduled compaction") {
                    Toggle("Auto-compact on a schedule", isOn: $compactionEnabled)
                        .disabled(saving)
                    if compactionEnabled {
                        HStack {
                            Text("Every")
                            Stepper(value: $compactionInterval, in: 1...30) {
                                Text("\(compactionInterval)").monospacedDigit()
                            }
                            .labelsHidden()
                            Picker("", selection: $compactionUnit) {
                                ForEach(CompactionUnit.allCases) { unit in
                                    Text(unit.label).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 120)
                        }
                        .disabled(saving)

                        HStack {
                            Text("At")
                            Stepper(value: $compactionHour, in: 0...23) {
                                Text(String(format: "%02d:00", compactionHour))
                                    .monospacedDigit()
                            }
                            .labelsHidden()
                            Text("(\(compactionTimezone))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .disabled(saving)

                        Text("BorgBase will run `borg compact` on this repo automatically in its own infra, reclaiming space freed by pruned archives without touching your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .padding(18)
        .frame(width: 520, height: 560)
        .onAppear { seedFromRepo() }
        .alert(
            "Error",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            ),
            actions: { Button("OK") { error = nil } },
            message: { Text(error ?? "") }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.wrench")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit \(repo.name)").font(.title3.bold())
                Text("Settings stored on BorgBase — changes apply server-side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(saving)
            Button("Save") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        guard !saving else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if quotaEnabled && parsedQuotaMB == nil { return false }
        return true
    }

    /// Parses the user-entered GB string to MB (what the API expects).
    /// Returns nil for invalid/empty input so the form can disable Save.
    private var parsedQuotaMB: Int? {
        let trimmed = quotaGB
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let gb = Double(trimmed), gb > 0 else { return nil }
        return Int(gb * 1000)
    }

    private var formattedCreatedAt: String? {
        guard let s = repo.createdAt, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: s) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }()
        guard let date else { return s }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }

    private func seedFromRepo() {
        name = repo.name
        quotaEnabled = repo.quotaEnabled ?? false
        if let q = repo.quota, q > 0 {
            // Stored as MB, shown as GB. Strip trailing .0 for whole numbers.
            let gb = q / 1000
            quotaGB = (gb.truncatingRemainder(dividingBy: 1) == 0)
                ? String(Int(gb))
                : String(format: "%.2f", gb)
        } else {
            quotaGB = ""
        }
        alertDays = repo.alertDays ?? 0

        compactionEnabled = repo.compactionEnabled ?? false
        compactionInterval = max(1, repo.compactionInterval ?? 1)
        if let unit = repo.compactionIntervalUnit,
           let parsed = CompactionUnit(rawValue: unit.lowercased()) {
            compactionUnit = parsed
        }
        compactionHour = (repo.compactionHour ?? 3).clamped(to: 0...23)
        if let tz = repo.compactionHourTimezone, !tz.isEmpty {
            compactionTimezone = tz
        }

        var map: [String: AccessLevel] = [:]
        (repo.fullAccessKeys ?? []).forEach     { map[$0] = .full }
        (repo.appendOnlyKeys ?? []).forEach     { map[$0] = .appendOnly }
        (repo.rsyncKeys ?? []).forEach          { map[$0] = .rsync }
        accessByKey = map
    }

    private func save() async {
        saving = true
        defer { saving = false }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newName: String? = (trimmed != repo.name) ? trimmed : nil

        let currentEnabled = repo.quotaEnabled ?? false
        let newQuotaEnabled: Bool? = (quotaEnabled != currentEnabled) ? quotaEnabled : nil

        // Only push quota when it's enabled — sending quota:0 with the
        // toggle on would let BorgBase reject the request for being at/under
        // the current usage. When the toggle is off the server ignores the
        // value anyway.
        var newQuota: Int? = nil
        if quotaEnabled {
            let storedMB = Int(repo.quota ?? 0)
            if let mb = parsedQuotaMB, mb != storedMB {
                newQuota = mb
            }
        }

        let currentAlert = repo.alertDays ?? 0
        let newAlertDays: Int? = (alertDays != currentAlert) ? alertDays : nil

        let currentCompactEnabled = repo.compactionEnabled ?? false
        let newCompactEnabled: Bool? = (compactionEnabled != currentCompactEnabled) ? compactionEnabled : nil

        // Only push interval/unit/hour/tz when the schedule is on. Server
        // ignores them otherwise, and sending them unchanged when the repo
        // is freshly-initialised would serialise whatever random defaults we
        // picked into the user's settings.
        var newCompactInterval: Int? = nil
        var newCompactUnit: String? = nil
        var newCompactHour: Int? = nil
        var newCompactTZ: String? = nil
        if compactionEnabled {
            if compactionInterval != (repo.compactionInterval ?? -1) {
                newCompactInterval = compactionInterval
            }
            if compactionUnit.rawValue != (repo.compactionIntervalUnit?.lowercased() ?? "") {
                newCompactUnit = compactionUnit.rawValue
            }
            if compactionHour != (repo.compactionHour ?? -1) {
                newCompactHour = compactionHour
            }
            if compactionTimezone != (repo.compactionHourTimezone ?? "") {
                newCompactTZ = compactionTimezone
            }
        }

        // ACL diff: if ANY of the three lists changed, send all three together.
        // BorgBase validates "a key can't be in two roles at once" across the
        // submitted payload, so moving a key between lists only works when
        // both the destination and the source list are sent in the same
        // mutation — otherwise the server sees the key in two roles and
        // rejects with "Can't use a SSH key for different roles."
        let desiredFull = Set(accessByKey.compactMap { $0.value == .full ? $0.key : nil })
        let desiredAppend = Set(accessByKey.compactMap { $0.value == .appendOnly ? $0.key : nil })
        let desiredRsync = Set(accessByKey.compactMap { $0.value == .rsync ? $0.key : nil })
        let currentFull = Set(repo.fullAccessKeys ?? [])
        let currentAppend = Set(repo.appendOnlyKeys ?? [])
        let currentRsync = Set(repo.rsyncKeys ?? [])

        let aclChanged = desiredFull != currentFull
            || desiredAppend != currentAppend
            || desiredRsync != currentRsync
        var newFull:   [String]? = nil
        var newAppend: [String]? = nil
        var newRsync:  [String]? = nil
        if aclChanged {
            newFull   = Array(desiredFull)
            newAppend = Array(desiredAppend)
            newRsync  = Array(desiredRsync)
        }

        do {
            try await BorgBaseClient.shared.updateRepo(
                id: repo.id,
                name: newName,
                quota: newQuota,
                quotaEnabled: newQuotaEnabled,
                alertDays: newAlertDays,
                compactionEnabled: newCompactEnabled,
                compactionInterval: newCompactInterval,
                compactionIntervalUnit: newCompactUnit,
                compactionHour: newCompactHour,
                compactionHourTimezone: newCompactTZ,
                fullAccessKeys: newFull,
                appendOnlyKeys: newAppend,
                rsyncKeys: newRsync
            )
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
