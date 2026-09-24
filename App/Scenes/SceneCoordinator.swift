import Effects
import Foundation
import GoveeLAN
import Observation

/// Everything the app knows about scenes that is not the ticking itself.
///
/// Split out of `AppModel` the way `BulbIdentifier` was: the model wires the app together
/// and should not also grow a second engine's worth of state. This owns the engine, keeps
/// the state the UI reads, and holds the one rule that is neither the engine's business
/// nor the store's: a scene and Party Mode are mutually exclusive, so whoever turns one on
/// turns the other off.
///
/// It is told which bulbs, which palette and which speed rather than reading them: the
/// model owns the settings and the bulb order, and one owner is enough.
@MainActor
@Observable
final class SceneCoordinator {

    private(set) var state: SceneEngine.State = .off
    /// How far through Sunset, 0 through 1, or `nil` for every other scene. The progress
    /// bar in the Scenes section reads this.
    private(set) var progress: Double?

    @ObservationIgnored private let engine: SceneEngine

    init(controller: BulbController,
         tickSource: any TickSource,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = SceneEngine(controller: controller, tickSource: tickSource, clock: clock)
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
        }
        engine.onProgressChange = { [weak self] newProgress in
            self?.progress = newProgress
        }
    }

    var isRunning: Bool {
        state != .off
    }

    /// The scene that is on screen right now, which is not the same as the stored one:
    /// the stored one is what the picker shows whether or not anything is running.
    var runningKind: SceneKind? {
        state.kind
    }

    /// Starts the given scene. The caller has already switched Party Mode off.
    func start(bulbs: [Bulb],
               kind: SceneKind,
               palette: Palette,
               speed: Double,
               singleColor: Bool) {
        engine.start(bulbs: bulbs,
                     kind: kind,
                     palette: palette,
                     speed: speed,
                     singleColor: singleColor)
    }

    func stop() {
        engine.stop()
    }

    /// Picking another scene while one is running swaps it live. Picking one while
    /// nothing is running only changes what the picker shows, because scenes never start
    /// themselves.
    func setScene(_ kind: SceneKind) {
        engine.setScene(kind)
    }

    func setPalette(_ palette: Palette) {
        engine.setPalette(palette)
    }

    func setSpeed(_ speed: Double) {
        engine.setSpeed(speed)
    }

    /// Static only: one color for the whole room instead of the palette spread along it.
    func setSingleColor(_ enabled: Bool) {
        engine.setSingleColor(enabled)
    }

    func updateBulbs(_ bulbs: [Bulb]) {
        guard isRunning else { return }
        engine.updateBulbs(bulbs)
    }
}
