import AppKit
import SwiftUI

/// The one way to support Glowbeat: a Ko-fi page, reached from the app menu and from a
/// quiet line at the bottom of Settings. Never a pop-up, a badge or a reminder.
enum Support {
    static let donationURL = URL(string: "https://ko-fi.com/philwoolley")!

    static let menuTitle = "Support Glowbeat\u{2026}"
    static let settingsLine = "Glowbeat is free. If it made your room better, you can buy me a coffee."
    static let linkTitle = "Buy me a coffee"

    static func openDonationPage() {
        NSWorkspace.shared.open(donationURL)
    }
}

/// The quiet line at the bottom of the Settings window, under both tabs.
struct SupportFooter: View {
    var body: some View {
        VStack(spacing: 2) {
            Text(Support.settingsLine)
                .foregroundStyle(.secondary)
            Link(Support.linkTitle, destination: Support.donationURL)
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
