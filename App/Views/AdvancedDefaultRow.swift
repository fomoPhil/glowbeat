import SwiftUI

/// The last row inside Advanced: put the four sliders back, or keep where they are.
///
/// Phil asked for both at once, and they are two halves of one idea. Advanced is the only
/// place in the app where someone can get lost: four sliders with no wrong answer and no
/// way back. Reset is the way back, and Save as default is what decides where back is.
///
/// Both are dimmed when the four values already are the default, which is the state a
/// fresh install starts in. Two dimmed buttons say "there is nothing to undo here yet"
/// better than two live ones that do nothing.
struct AdvancedDefaultRow: View {

    @Bindable var model: AppModel

    /// How long "Saved" stays up. Long enough to read, short enough that nobody waits for
    /// it before moving on.
    static let confirmationDuration: Duration = .seconds(1.5)

    static let saveTitle = "Save as default"
    static let savedTitle = "Saved"
    static let resetTitle = "Reset"
    static let saveHelp = "Keep these four settings as the default Reset returns to"
    static let savedDefaultHelp = "Back to your saved default"
    static let shippedDefaultHelp = "Back to Punchy"

    /// The gap between the two buttons.
    private static let spacing: CGFloat = 12

    /// Bumped on every save, so the confirmation's timer restarts rather than a second
    /// save inheriting whatever was left of the first one's.
    @State private var saveCount = 0
    @State private var isShowingSaved = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Self.spacing) {
            // Right aligned: these two act on everything above them, so they read as the
            // end of the group rather than as another setting in it.
            Spacer(minLength: 0)
            resetButton
            saveControl
        }
        .frame(minHeight: PartyStyle.rowHeight)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isShowingSaved)
        .task(id: saveCount) { await withdrawConfirmation() }
    }

    private var resetButton: some View {
        Button {
            model.resetAdvanced()
        } label: {
            Label(Self.resetTitle, systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(PartyButtonStyle(weight: .secondary))
        .disabled(!model.canResetAdvanced)
        .help(resetHelp)
        .accessibilityLabel("Reset the Advanced settings")
        .accessibilityHint(resetHelp)
    }

    /// The prominent half, in a slot the width of its longest label.
    ///
    /// "Saved" is shorter than "Save as default", so without the slot the row would jump
    /// left for a second and a half every time someone saved.
    private var saveControl: some View {
        ZStack {
            Text(Self.saveTitle)
                .font(PartyStyle.label)
                .padding(.horizontal, PartyButtonStyle.horizontalPadding)
                .hidden()
                .accessibilityHidden(true)

            if isShowingSaved {
                confirmation
            } else {
                saveButton
            }
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text(Self.saveTitle)
        }
        .buttonStyle(PartyButtonStyle(weight: .prominent))
        .disabled(!model.canSaveAdvancedAsDefault)
        .help(Self.saveHelp)
        .accessibilityLabel(Self.saveTitle)
        .accessibilityHint(Self.saveHelp)
    }

    /// Not a button. Saving makes both buttons dim, because there is nothing left to
    /// save, and a dimmed confirmation is a confirmation nobody can read.
    private var confirmation: some View {
        Label(Self.savedTitle, systemImage: "checkmark")
            .partyButtonFace(.prominent, fillsWidth: true)
            .accessibilityLabel("Saved as default")
    }

    private var resetHelp: String {
        Self.resetHelp(hasSavedDefault: model.settings.savedAdvancedDefault != nil)
    }

    /// "Back to Punchy" until there is something of the user's own to go back to. The
    /// button does the same thing either way; the help text is the only place the app can
    /// say which default it means. Pure, so the rule can be read and tested without a
    /// model to ask.
    static func resetHelp(hasSavedDefault: Bool) -> String {
        hasSavedDefault ? savedDefaultHelp : shippedDefaultHelp
    }

    private func save() {
        model.saveAdvancedAsDefault()
        isShowingSaved = true
        saveCount += 1
    }

    /// Runs on every change of `saveCount`, which cancels the previous one, so saving
    /// twice in a row shows "Saved" for a second and a half from the second save rather
    /// than from the first.
    private func withdrawConfirmation() async {
        guard isShowingSaved else { return }
        try? await Task.sleep(for: Self.confirmationDuration)
        guard !Task.isCancelled else { return }
        isShowingSaved = false
    }
}
