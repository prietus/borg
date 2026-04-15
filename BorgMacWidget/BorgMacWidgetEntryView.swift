import SwiftUI
import WidgetKit
import Charts

struct BorgMacWidgetEntryView: View {
    let entry: BorgMacWidgetEntry
    @Environment(\.widgetFamily) private var family

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        switch family {
        case .systemLarge:
            largeBody
        default:
            mediumBody
        }
    }

    // MARK: - Medium

    /// Compact layout: one-line header + provider bars + footer.
    /// Optimised so the total usage number is the first thing the eye
    /// lands on, because that's what the user glances at the widget
    /// for most of the time.
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            providerBars(maxCount: 3)
            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 4)
    }

    // MARK: - Large

    /// Rich layout mirroring `StatsPanel`: totals row, a donut for
    /// provider breakdown (same SectorMark as the panel's "By provider"
    /// chart), top-5 repo bars, and the next-backup footer.
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().opacity(0.5)
            sectionLabel("Por proveedor")
            providerDonut
            if !entry.snapshot.topRepos.isEmpty {
                Divider().opacity(0.5)
                sectionLabel("Por repositorio")
                repoBars
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 4)
    }

    /// Donut + inline legend. Mirrors the "By provider" donut in the
    /// Stats panel (same `SectorMark`, same `innerRadius`) so the two
    /// surfaces read as variations of the same chart.
    @ViewBuilder
    private var providerDonut: some View {
        let items = entry.snapshot.byProvider
        if items.isEmpty {
            Text("Abre BorgMac para generar estadísticas")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 14) {
                Chart(items) { usage in
                    SectorMark(
                        angle: .value("Bytes", Double(usage.bytes)),
                        innerRadius: .ratio(0.62),
                        angularInset: 1
                    )
                    .foregroundStyle(Self.color(for: usage.providerKey))
                }
                .chartLegend(.hidden)
                .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { usage in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Self.color(for: usage.providerKey))
                                .frame(width: 8, height: 8)
                            Text(usage.label)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.bytes.string(fromByteCount: usage.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Shared pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(family == .systemLarge ? .title2 : .body)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.bytes.string(fromByteCount: entry.snapshot.totalUsageBytes))
                    .font((family == .systemLarge ? Font.title : Font.title2).bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    metricChip(
                        value: "\(entry.snapshot.repoCount)",
                        label: entry.snapshot.repoCount == 1 ? "repo" : "repos"
                    )
                    if entry.snapshot.archiveCount > 0 {
                        metricChip(
                            value: "\(entry.snapshot.archiveCount)",
                            label: entry.snapshot.archiveCount == 1 ? "archivo" : "archivos"
                        )
                    }
                }
            }
            Spacer()
            healthDot
        }
    }

    private func metricChip(value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.caption2.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .kerning(0.4)
    }

    /// Horizontal bars keyed to the largest provider — so a provider
    /// holding 80% of the total actually *looks* 80% wide, instead of
    /// the flat legend dots of the old layout.
    private func providerBars(maxCount: Int) -> some View {
        let items = Array(entry.snapshot.byProvider.prefix(maxCount))
        let maxBytes = items.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Text("Abre BorgMac para generar estadísticas")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(items) { usage in
                    HStack(spacing: 6) {
                        Text(usage.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 62, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.tertiary)
                                    .frame(height: 6)
                                Capsule()
                                    .fill(Self.color(for: usage.providerKey))
                                    .frame(
                                        width: Self.barWidth(
                                            value: usage.bytes,
                                            max: maxBytes,
                                            total: geo.size.width
                                        ),
                                        height: 6
                                    )
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 10)
                        Text(Self.bytes.string(fromByteCount: usage.bytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Mini-bar per repo, same scale normalisation as the provider
    /// strip. Truncates long names in the middle so suffixes like
    /// "-borgbase" remain visible.
    private var repoBars: some View {
        let items = entry.snapshot.topRepos
        let maxBytes = items.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { repo in
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.tertiary)
                                .frame(height: 5)
                            Capsule()
                                .fill(Self.color(for: repo.providerKey))
                                .frame(
                                    width: Self.barWidth(
                                        value: repo.bytes,
                                        max: maxBytes,
                                        total: geo.size.width
                                    ),
                                    height: 5
                                )
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 8)
                    Text(Self.bytes.string(fromByteCount: repo.bytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let next = entry.snapshot.nextBackup {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Próx. \(next.repoName) · \(next.scheduleName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(Self.relative.localizedString(for: next.fireDate, relativeTo: entry.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Sin backups programados")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthDot: some View {
        let color: Color
        let symbol: String
        switch entry.snapshot.health {
        case .ok:
            color = .green; symbol = "checkmark.circle.fill"
        case .running:
            color = .orange; symbol = "arrow.triangle.2.circlepath"
        case .error:
            color = .red; symbol = "exclamationmark.triangle.fill"
        }
        return Image(systemName: symbol)
            .font(.footnote)
            .foregroundStyle(color)
    }

    /// Computes a bar width proportional to `value / max`, clamped so
    /// zero-byte entries still show a faint sliver rather than
    /// disappearing. Kept static so SwiftUI doesn't invalidate views
    /// on every evaluation.
    private static func barWidth(value: Int64, max: Int64, total: CGFloat) -> CGFloat {
        guard max > 0, total > 0 else { return 0 }
        let ratio = CGFloat(value) / CGFloat(max)
        return Swift.max(4, total * ratio)
    }

    /// Keeps the widget's provider palette in sync with `StatsPanel`
    /// (`Provider.tint`). Hard-coded by rawValue since the extension
    /// target doesn't import the host's private `Provider` enum.
    static func color(for providerKey: String) -> Color {
        switch providerKey {
        case "local":    return .blue
        case "borgBase": return .green
        case "borgBox":  return .yellow
        default:         return .secondary
        }
    }
}
