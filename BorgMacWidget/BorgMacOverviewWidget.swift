import SwiftUI
import WidgetKit

struct BorgMacOverviewWidget: Widget {
    let kind: String = "BorgMacOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BorgMacWidgetProvider()) { entry in
            BorgMacWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("BorgMac")
        .description("Resumen de uso y próximo backup programado.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// Timeline provider backed by the JSON snapshot the host app writes
/// after each `StatsPanel` load and each schedule edit. We don't have
/// live access to the `borg` CLI from the extension (sandboxing aside,
/// launching subprocesses from a widget is a non-starter), so the
/// widget is strictly a view onto whatever the host last persisted.
///
/// Refresh cadence: every 15 minutes. That's frequent enough that the
/// "próximo en Xh" countdown stays visually correct and cheap enough
/// that WidgetKit doesn't complain about budget. Each refresh simply
/// re-reads the file; if the host hasn't updated it, we still render
/// the previous payload with a fresh `now` for time-relative strings.
struct BorgMacWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BorgMacWidgetEntry {
        BorgMacWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BorgMacWidgetEntry) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        completion(BorgMacWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BorgMacWidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        let entry = BorgMacWidgetEntry(date: Date(), snapshot: snapshot)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BorgMacWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

extension WidgetSnapshot {
    /// Empty-state shown on first install (no snapshot on disk yet) or
    /// when the JSON fails to decode. The view renders a gentle "abre
    /// la app" prompt instead of zeros so the widget doesn't look
    /// broken.
    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        repoCount: 0,
        archiveCount: 0,
        totalUsageBytes: 0,
        byProvider: [],
        topRepos: [],
        nextBackup: nil,
        health: .ok
    )
}
