import SwiftUI

/// Press feedback for everything in the Party panel that is not a stock AppKit control:
/// the control shrinks to `PartyStyle.pressScale` while it is held.
///
/// 0.96 and no less. Anything smaller stops reading as "this is under my finger" and
/// starts reading as an animation. Someone who has asked the system for less movement
/// gets no scale at all, because this is feedback rather than information.
struct PartyPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    /// A view rather than the style's own body: `@Environment` only tracks changes
    /// inside a `View`, so a style that read Reduce Motion directly would keep whatever
    /// the setting was when the app launched.
    private struct Pressable: View {

        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(scale)
                .animation(PartyStyle.motion(PartyStyle.press, reduceMotion: reduceMotion),
                           value: configuration.isPressed)
        }

        private var scale: CGFloat {
            guard configuration.isPressed, !reduceMotion else { return 1 }
            return PartyStyle.pressScale
        }
    }
}
