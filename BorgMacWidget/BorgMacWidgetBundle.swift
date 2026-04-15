import SwiftUI
import WidgetKit

/// WidgetKit entry point for the extension. The bundle currently ships
/// a single widget (`BorgMacOverviewWidget`) in the `systemMedium`
/// family. If we add more surfaces later — e.g. a small "next backup
/// only" widget — they join here.
@main
struct BorgMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        BorgMacOverviewWidget()
    }
}
