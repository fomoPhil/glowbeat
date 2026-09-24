import Foundation
import GoveeLAN

/// Flashes one bulb so the user can tell which lamp in the room a row belongs to.
///
/// Split out of `AppModel` because the sequence is a small state machine with its own
/// timing, cancellation and restore rules, and none of that belongs in the object that
/// wires the app together. `AppModel` owns one of these and keeps the decisions that
/// need the rest of the app, above all whether a flash is allowed to start at all.
@MainActor
@Observable
final class BulbIdentifier {

    /// The color a flash uses. Plain white rather than a Kelvin, because a bulb that was
    /// already in white mode should still visibly change when it flashes.
    static let white = GoveeRGB(r: 255, g: 255, b: 255)

    /// The bulbs mid flash. A row disables its own button on this, and a second tap on
    /// the same bulb is dropped rather than interleaving two sequences of power commands.
    private(set) var flashingBulbIDs: Set<String> = []

    /// Spacing between the steps of a flash: on, off, on, off, restore. Five steps
    /// 350 ms apart is the "about 1.5 s" of the spec.
    private(set) var stepInterval: TimeInterval = 0.35

    /// One run per bulb currently flashing. The token is what lets a run that was
    /// canceled tell itself apart from a later run on the same bulb.
    private struct Run {
        var token: UUID
        var task: Task<Void, Never>
    }

    private let controller: BulbController
    @ObservationIgnored private var runs: [String: Run] = [:]

    init(controller: BulbController) {
        self.controller = controller
    }

    deinit {
        for run in runs.values { run.task.cancel() }
    }

    /// Only tests call this, so a flash does not cost a second and a half of a suite.
    /// The shipping value is the property's own default and nothing in the app writes it.
    func setStepInterval(_ seconds: TimeInterval) {
        stepInterval = max(0, seconds)
    }

    func isFlashing(_ bulbID: String) -> Bool {
        flashingBulbIDs.contains(bulbID)
    }

    /// Flashes the bulb white, off, white, off and then puts it back the way `restore`
    /// describes it.
    ///
    /// The restore sends the color or the Kelvin first and the power last, so a bulb that
    /// was off ends up off however the hardware reacts to a color sent to a bulb that is
    /// not lit. Brightness is never touched, which is what "white at the current
    /// brightness" means. With no state to restore, or one carrying no usable color, the
    /// bulb is left white and only its power is put back.
    func start(_ bulb: Bulb, restore: BulbState?) {
        guard runs[bulb.id] == nil else { return }
        let interval = stepInterval
        let token = UUID()
        flashingBulbIDs.insert(bulb.id)
        let task = Task { [weak self, controller] in
            // Cancellation is checked before every send, not only across the gaps. Each
            // send is an await on an actor, so a cancel can land between any two of them,
            // and the whole point of the cancel is that Party Mode is about to own this
            // bulb. An early return leaves the state alone: `cancelAll` has already
            // cleared it, and what sits there now may belong to a later flash.
            guard !Task.isCancelled else { return }
            await controller.turn(true, bulbs: [bulb])
            guard !Task.isCancelled else { return }
            await controller.setColor(Self.white, bulbs: [bulb])

            for isOn in [false, true, false] {
                guard await Self.pause(interval), !Task.isCancelled else { return }
                await controller.turn(isOn, bulbs: [bulb])
            }

            guard await Self.pause(interval), !Task.isCancelled else { return }
            if let restore, let command = Self.restoreCommand(for: restore) {
                switch command {
                case .kelvin(let value):
                    await controller.setColorTemperature(kelvin: value, bulbs: [bulb])
                case .rgb(let value):
                    await controller.setColor(value, bulbs: [bulb])
                }
                guard !Task.isCancelled else { return }
            }
            await controller.turn(restore?.isOn ?? true, bulbs: [bulb])
            self?.finish(bulb.id, token: token)
        }
        runs[bulb.id] = Run(token: token, task: task)
    }

    /// Stops every flash. Party Mode calls this before it starts streaming, because one
    /// shot commands landing inside the stream would leave a bulb wherever the collision
    /// fell, and `stopServices` calls it because the socket is about to close.
    func cancelAll() {
        for run in runs.values { run.task.cancel() }
        runs.removeAll()
        flashingBulbIDs.removeAll()
    }

    // MARK: Internals

    private enum RestoreCommand {
        case kelvin(Int)
        case rgb(GoveeRGB)
    }

    /// What to send to put a bulb back the way it was reported. Nothing, when white mode
    /// is off and the reported color is black: that is a bulb nobody has ever given a
    /// color, and sending the black back would put it out rather than restore it.
    private static func restoreCommand(for state: BulbState) -> RestoreCommand? {
        if state.colorTemperatureKelvin > 0 { return .kelvin(state.colorTemperatureKelvin) }
        guard state.color != GoveeRGB(r: 0, g: 0, b: 0) else { return nil }
        return .rgb(state.color)
    }

    /// Only the run that is still the current one may clear the state.
    private func finish(_ bulbID: String, token: UUID) {
        guard runs[bulbID]?.token == token else { return }
        flashingBulbIDs.remove(bulbID)
        runs[bulbID] = nil
    }

    /// Sleeps between the steps of a flash. Returns false when the flash was canceled,
    /// which is the caller's cue to stop sending.
    private static func pause(_ seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}
