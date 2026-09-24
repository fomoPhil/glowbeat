import Foundation
import GoveeLAN

/// Decides whether a bulb's reported state came from the Govee phone app rather than
/// from Glowbeat. See spec section 4.4, as amended by section S of the v1.2 addendum.
struct ExternalChangeDetector: Sendable {

    /// Per channel slack when matching a reported color against a color the app sent, or
    /// against the fade from one sent color to the next.
    static let colorTolerance = 8

    /// How many consecutive polls must agree on one color Glowbeat cannot account for
    /// before that counts as a takeover.
    ///
    /// A phone sets a color and leaves it there. Nearly everything else that makes a bulb
    /// report a color the app cannot place is on the move: a bulb that fell behind on a
    /// busy network catches up, and a fade the next send interrupted heads somewhere new.
    /// So one poll is never enough, two in a row still paused Phil's ten bulbs for nothing
    /// (2026-09-23), and the three have to agree with each other (`ColorMismatchRun`). At
    /// one poll a second that pauses two to three seconds after the phone. Power and
    /// brightness have no fade and no send history to fall out of, and still pause on the
    /// first mismatch.
    static let colorPollsBeforePause = 3

    /// What Glowbeat believes it last told this bulb. Nil means "not set by the app yet",
    /// which never counts as a change.
    struct Expectation: Equatable, Sendable {
        var expectedPower: Bool?
        var expectedBrightness: Int?
        /// Every color the app sent this bulb that could explain the report, oldest first,
        /// in the order they went out: `BulbController.sentColorHistory(for:asOf:)`, which
        /// is time bounded. The order matters, since the bulb fades from each one to the
        /// next. Empty means nothing has been sent yet, which never counts as a change.
        var recentColors: [GoveeRGB]

        init(expectedPower: Bool?, expectedBrightness: Int?, recentColors: [GoveeRGB]) {
            self.expectedPower = expectedPower
            self.expectedBrightness = expectedBrightness
            self.recentColors = recentColors
        }
    }

    enum Finding: Equatable, Sendable {
        case none
        case power
        case brightness
        case color

        /// The text the Party Mode toggle shows when paused.
        var reason: String? {
            switch self {
            case .none: return nil
            case .power: return "Paused: a bulb was switched from the Govee app."
            case .brightness: return "Paused: brightness was changed from the Govee app."
            case .color: return "Paused: a color was changed from the Govee app."
            }
        }
    }

    /// One bulb's run of consecutive polls that each reported a color the app cannot
    /// account for. A poll that finds nothing, or finds power or brightness instead, ends
    /// the run.
    struct ColorMismatchRun: Equatable, Sendable {
        private(set) var count = 0
        /// The lowest and highest value each channel has taken in this run.
        private var low = GoveeRGB.black
        private var high = GoveeRGB.black

        /// Adds one poll's unexplained color. A color that does not sit with the whole
        /// run, within `colorTolerance` of every earlier one on every channel, starts the
        /// run again from itself: that is a bulb still moving, not a phone.
        mutating func add(_ color: GoveeRGB) {
            let widerLow = GoveeRGB(r: min(low.r, color.r), g: min(low.g, color.g), b: min(low.b, color.b))
            let widerHigh = GoveeRGB(r: max(high.r, color.r), g: max(high.g, color.g), b: max(high.b, color.b))
            if count > 0, widerHigh.channelDistance(to: widerLow) <= ExternalChangeDetector.colorTolerance {
                count += 1
                low = widerLow
                high = widerHigh
            } else {
                count = 1
                low = color
                high = color
            }
        }

        /// True once enough polls in a row agree on one color to pause Party Mode over.
        var isTakeover: Bool {
            count >= ExternalChangeDetector.colorPollsBeforePause
        }
    }

    /// Which brightness each bulb has been seen at since Glowbeat last set one, so a
    /// brightness the app just sent is not judged before it has landed.
    ///
    /// Party Mode and the scenes set every bulb's own brightness to 100 as they start
    /// (they do their dimming in the colors they send). That goes out as UDP, with its
    /// repeats a second apart, so a bulb can answer a poll or two still at the brightness
    /// it had before. Judged straight away, that is Glowbeat's own command read as the
    /// Govee phone app. So a brightness the app sent is only judged once the bulb has
    /// reported it at least once; until then the report is not judged on brightness at
    /// all, and power and color are judged as they always were. Each new value Glowbeat
    /// sends, the All bulbs slider dragged mid session for one, has to be shown again.
    ///
    /// The cost: a phone that changes the brightness before the bulb has ever shown
    /// Glowbeat's value goes unnoticed on brightness for that session. That is a second
    /// or two at the start of a session, and the phone's color or power still pauses.
    struct BrightnessCheck: Equatable, Sendable {
        /// Per bulb, the brightness Glowbeat sent that the bulb has since reported.
        private var shown: [String: Int] = [:]

        /// Notes what `bulbID` just reported and returns the brightness to judge that
        /// report against: what Glowbeat last sent, once the bulb has shown it; the
        /// session's `baseline` when Glowbeat has sent none; and nil, nothing to judge,
        /// while a sent brightness has not been seen yet.
        mutating func expectation(for bulbID: String,
                                  reported: Int,
                                  sent: Int?,
                                  baseline: Int?) -> Int? {
            guard let sent else { return baseline }
            if reported == sent {
                shown[bulbID] = sent
            }
            return shown[bulbID] == sent ? sent : nil
        }

        /// A new session, or a resumed one: nothing sent before it has been seen yet.
        mutating func reset() {
            shown.removeAll()
        }
    }

    func evaluate(reported: BulbState, expectation: Expectation) -> Finding {
        if let expectedPower = expectation.expectedPower, reported.isOn != expectedPower {
            return .power
        }
        if let expectedBrightness = expectation.expectedBrightness,
           reported.brightness != expectedBrightness {
            return .brightness
        }
        guard !expectation.recentColors.isEmpty else { return .none }
        return Self.isExplained(reported.color, bySent: expectation.recentColors) ? .none : .color
    }

    /// Whether a bulb that was sent `sent`, oldest first, could be showing `color`: it is
    /// within `colorTolerance` of one of them, or of the straight line the H6004's
    /// firmware fades along from one of them to the next.
    static func isExplained(_ color: GoveeRGB, bySent sent: [GoveeRGB]) -> Bool {
        if sent.contains(where: { $0.channelDistance(to: color) <= colorTolerance }) {
            return true
        }
        return zip(sent, sent.dropFirst()).contains { from, to in
            isOnFade(color, from: from, to: to)
        }
    }

    /// Whether one point on the fade from `start` to `end` is within `colorTolerance` of
    /// `color` on every channel. Each channel allows a stretch of the fade (a range of
    /// how far along it the bulb is), and the color is on the fade when the three
    /// stretches overlap.
    private static func isOnFade(_ color: GoveeRGB, from start: GoveeRGB, to end: GoveeRGB) -> Bool {
        let slack = Double(colorTolerance)
        var earliest = 0.0
        var latest = 1.0
        let channels = [(color.r, start.r, end.r), (color.g, start.g, end.g), (color.b, start.b, end.b)]
        for (value, from, to) in channels {
            let offset = Double(value) - Double(from)
            let span = Double(to) - Double(from)
            if span == 0 {
                guard abs(offset) <= slack else { return false }
                continue
            }
            let one = (offset - slack) / span
            let other = (offset + slack) / span
            earliest = max(earliest, min(one, other))
            latest = min(latest, max(one, other))
            // A hair of slack for floating point at exactly the tolerance.
            guard earliest <= latest + 1e-9 else { return false }
        }
        return true
    }
}
