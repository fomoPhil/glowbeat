import SwiftUI

/// One block of the Party panel: a heading, a control, and the line underneath that says
/// what the control does.
///
/// Every section is built the same way so the panel has one rhythm down its whole length
/// rather than a different gap above each control.
struct PartySection<Content: View>: View {

    var title: String?
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PartyStyle.captionSpacing) {
            if let title {
                Text(title)
                    .font(PartyStyle.sectionTitle)
            }
            content
            if let caption {
                Text(caption)
                    .font(PartyStyle.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
