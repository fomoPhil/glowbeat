import SwiftUI

/// The Party panel's design tokens, taken from the "05 Minimal 2026" mockup
/// (`docs/design/mockups/05-minimal.html`), which is the source of truth for the look.
///
/// One surface, one accent, one glass sheet. Every number the panel draws with lives
/// here so the look can be moved in one place rather than in nine files, and so the
/// radii stay concentric: an outer radius is always its inner radius plus the padding
/// between them, which is the difference between a panel that reads as machined and one
/// that reads as nested rectangles.
enum PartyStyle {

    // MARK: Color

    /// The one accent: the color of a bulb on its way up. Dark #ffb43c, light #a25e00,
    /// from the asset catalog so both appearances are first class. It means "live" or
    /// "picked" and nothing else, which is what keeps one amber marker on a neutral
    /// meter readable at a glance.
    static let accent = Color("PartyAccent")

    /// The fill of a raised control, the selected segment. Lighter than the surface in
    /// the dark appearance and white in the light one, so it cannot be expressed as an
    /// opacity of `primary` the way the recessed tokens can.
    static let raised = Color("PartySegmentRaised")

    /// What is drawn on top of an amber fill. The accent is a light amber in the dark
    /// appearance and a dark one in the light appearance, so the label that sits on it
    /// has to flip with it rather than being one fixed color.
    static func onAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    /// A recessed well: the segmented control's bed, a slider's track, a checkbox at
    /// rest. `primary` rather than a fixed color, so it is white in the dark appearance
    /// and black in the light one without a second definition.
    static let trough = Color.primary.opacity(0.055)

    /// The meter, which stays neutral so the amber marker is the only accent shape on it.
    static let meterOff = Color.primary.opacity(0.085)
    static let meterOn = Color.primary.opacity(0.38)
    static let meterPeak = Color.primary.opacity(0.18)

    // MARK: Type

    // Three faces, each with one job (`docs/design/mockups/fonts.html`, pairing 2).
    //
    // SF Pro Rounded is the mood: the name of the feature and the names of the four
    // feels, which are the only words in the panel describing how something should feel
    // rather than what it is. SF Pro Text is everything else, because a label is a label.
    // SF Mono holds every number that moves, so a readout cannot change width under its
    // own value. All three ship with macOS, so nothing is bundled and nothing is
    // licensed.

    /// The name of the panel, on the switch that starts it. Rounded, because it is the
    /// one title in the app and the app is a party lights app.
    static let partyTitle = Font.system(.title3, design: .rounded, weight: .semibold)
    /// The name of the pane, at the top of the window's detail column. One step up from
    /// a section heading, because it names the whole of what is under it.
    static let paneTitle = Font.system(size: 17, weight: .semibold)
    /// The heading over a section of the panel.
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    /// The heading on the glass sheet, one step up because it is the hero. Text rather
    /// than rounded: "Trigger Level" is the name of a control, not a mood.
    static let heroTitle = Font.system(size: 15, weight: .semibold)
    /// The live percentage on the glass sheet. Display type: big, tight, and monospaced,
    /// so it cannot jiggle as the number changes.
    static let heroValue = Font.system(size: 28, weight: .semibold, design: .monospaced)
    /// A control's own label, and the text inside a segment.
    static let label = Font.body
    /// The name of a feel. The same size as `label`, rounded, because Punchy and Dreamy
    /// are moods rather than settings: they are the one place in the panel where the
    /// type should say something about how the room will feel.
    static let presetName = Font.system(.body, design: .rounded)
    /// Every number that changes while the panel is open: the percentages, the seconds,
    /// the bulbs per second. Monospaced so a readout holds its width and its column does
    /// not twitch as the value moves under it.
    static let readout = Font.system(.body, design: .monospaced)
    /// The line under a control that says what it does. `.callout` is 12 points on
    /// macOS, which is the mockup's caption size; `.caption` is 10 and reads as fine
    /// print next to a 13 point label.
    static let caption = Font.callout

    // MARK: Radii, concentric

    /// The radius of anything sitting inside something else. Every outer radius below is
    /// this plus the padding around it.
    static let innerRadius: CGFloat = 8

    static let sheetPadding: CGFloat = 16
    /// 8 + 16.
    static let sheetRadius: CGFloat = 24

    static let segmentPadding: CGFloat = 3
    /// 8 + 3.
    static let segmentedRadius: CGFloat = 11
    static let segmentHeight: CGFloat = 34

    static let chipPadding: CGFloat = 3
    /// 8 + 3.
    static let chipRadius: CGFloat = 11

    // MARK: Metrics

    /// The smallest a thing anyone has to hit may be. Controls that draw smaller than
    /// this carry an invisible hit region out to it.
    static let hitTarget: CGFloat = 40
    /// A control row is a hit target tall, so a row of them cannot end up with targets
    /// that overlap.
    static let rowHeight: CGFloat = 40
    /// Between the panel's sections.
    static let sectionSpacing: CGFloat = 22
    /// Between a control and the caption that explains it.
    static let captionSpacing: CGFloat = 11
    /// What a control shrinks to while it is held down.
    static let pressScale: CGFloat = 0.96
    /// What a control fades to when pressing it would do nothing. Faint enough to read
    /// as off, solid enough to still be read. The Trigger Level marker fades to the same
    /// amount while Always react is on, through `LevelMeter.disabledOpacity`.
    static let disabledOpacity: Double = 0.35

    // MARK: Motion

    /// For a state change the user asked for: a tap, a selection.
    static let quick = Animation.easeOut(duration: 0.15)
    /// For something settling by itself: a disclosure, a sheet.
    static let calm = Animation.easeOut(duration: 0.24)
    /// What a press scale runs on. Shorter than everything else, because the finger is
    /// already off the button by the time a longer one would finish.
    static let press = Animation.easeOut(duration: 0.1)

    /// The animation, or none at all for someone who asked the system for less movement.
    /// Passing nil to `.animation(_:value:)` is what turns a change into a cut.
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: Depth

    /// Layered transparent shadows rather than a border, so the sheet sits on whatever is
    /// behind it rather than being outlined against it. Two sets: a shadow that reads on
    /// a dark surface is invisible on a light one.
    static func sheetShadows(_ scheme: ColorScheme) -> ShadowStack {
        scheme == .dark
            ? ShadowStack(near: Shadow(opacity: 0.30, radius: 1, y: 1),
                          mid: Shadow(opacity: 0.40, radius: 12, y: 8),
                          far: Shadow(opacity: 0.45, radius: 30, y: 24))
            : ShadowStack(near: Shadow(opacity: 0.05, radius: 1, y: 1),
                          mid: Shadow(opacity: 0.12, radius: 10, y: 6),
                          far: Shadow(opacity: 0.16, radius: 22, y: 16))
    }

    /// The small lift under a raised control: a selected segment, a chosen palette.
    static func liftShadows(_ scheme: ColorScheme) -> ShadowStack {
        scheme == .dark
            ? ShadowStack(near: Shadow(opacity: 0.34, radius: 1, y: 1),
                          mid: Shadow(opacity: 0.24, radius: 4, y: 2),
                          far: Shadow(opacity: 0.10, radius: 8, y: 4))
            : ShadowStack(near: Shadow(opacity: 0.10, radius: 1, y: 1),
                          mid: Shadow(opacity: 0.06, radius: 3, y: 2),
                          far: Shadow(opacity: 0.04, radius: 7, y: 4))
    }

    /// What a raised control sits on when it is not raised: the other end of the hover
    /// and selection lift above.
    ///
    /// Not nothing at all. A swatch with no shadow beside one with a lift reads as a hole
    /// rather than as a card lying flat, and a lift animating out of zero pops rather
    /// than settles. One contact shadow, so the grid at rest is quiet.
    static func restShadows(_ scheme: ColorScheme) -> ShadowStack {
        scheme == .dark
            ? ShadowStack(near: Shadow(opacity: 0.22, radius: 1, y: 1),
                          mid: Shadow(opacity: 0, radius: 0, y: 0),
                          far: Shadow(opacity: 0, radius: 0, y: 0))
            : ShadowStack(near: Shadow(opacity: 0.07, radius: 1, y: 1),
                          mid: Shadow(opacity: 0, radius: 0, y: 0),
                          far: Shadow(opacity: 0, radius: 0, y: 0))
    }

    /// The tint laid over the glass itself. The mockup's sheet is a blur with a white
    /// film on top of it, not a bare blur: the film is what makes the sheet a surface in
    /// its own right rather than a slightly blurrier patch of window. It is also what
    /// keeps the sheet readable on a platform whose idea of glass is only a material.
    static func glassFilm(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(scheme == .dark ? 0.055 : 0.55)
    }

    /// The hairline highlight along the top of the glass sheet, which is what makes it
    /// read as a lit edge rather than as a lighter rectangle.
    static func edgeHighlight(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(scheme == .dark ? 0.14 : 0.90)
    }

    /// One layer of a layered shadow.
    struct Shadow: Equatable, Sendable {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    /// Three layers: the contact shadow, the body of it, and the soft one that does the
    /// actual separating. Fixed at three so applying them is three modifiers rather than
    /// a loop that would have to erase the view's type.
    struct ShadowStack: Equatable, Sendable {
        let near: Shadow
        let mid: Shadow
        let far: Shadow
    }
}

extension View {

    /// Shadows rather than a border, layered from contact outward.
    func partyShadows(_ stack: PartyStyle.ShadowStack) -> some View {
        shadow(color: .black.opacity(stack.near.opacity),
               radius: stack.near.radius,
               y: stack.near.y)
            .shadow(color: .black.opacity(stack.mid.opacity),
                    radius: stack.mid.radius,
                    y: stack.mid.y)
            .shadow(color: .black.opacity(stack.far.opacity),
                    radius: stack.far.radius,
                    y: stack.far.y)
    }
}
