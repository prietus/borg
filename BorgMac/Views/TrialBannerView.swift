import SwiftUI

/// A slim banner shown at the top of the main window when the trial is
/// ending or already expired. Kept intentionally passive — clicking the CTA
/// opens the Settings window; it never blocks the UI or steals focus.
struct TrialBannerView: View {
    @EnvironmentObject var license: LicenseManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let message = license.status.bannerText {
            HStack(spacing: 10) {
                Image(systemName: isExpired ? "exclamationmark.triangle.fill" : "clock.badge")
                    .foregroundStyle(isExpired ? .red : .yellow)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    license.openCheckout()
                } label: {
                    Text("Buy license")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Enter key")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
        }
    }

    private var isExpired: Bool {
        if case .expired = license.status { return true }
        return false
    }
}
