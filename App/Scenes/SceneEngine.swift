import Effects
import Foundation
import GoveeLAN
import OSLog

/// Runs a scene: a clock in, deduped `colorwc` sends out.
///
/// The same shape as `PartyEngine` with the audio taken out. It ticks four times a second
/// through the same `TickSource` abstraction, streams through the same rate limited
/// `BulbController` path, and dedupes so a scene that is holding still, Static above all,
/// costs no traffic after its first send.
///
/// Every command goes through one serial chain, so a color computed on an earlier tick
/// can never overtake a later one, and the lights out at the end of Sunset is always the
/// last thing a bulb hears.
@MainActor
final class SceneEngine {

    enum State: Equatable {
        case off
        case running(SceneKind)

        var kind: SceneKind? {
            if case .running(let kind) = self { return kind }
            return nil
        }
    }

    private(set) var state: State = .off
    /// How far through a scene with an end. `nil` for every scene that runs until it is
    /// switched off, which is all of them except Sunset.
    private(set) var progress: Double?

    var onStateChange: (@MainActor (State) -> Void)?
    var onProgressChange: (@MainActor (Double?) -> Void)?

    private let controller: BulbController
    private let tickSource: any TickSource
    /// The monotonic clock the scenes are driven by. Injectable so a test can prove a
    /// twenty minute Sunset without waiting twenty minutes for it.
    private let clock: @Sendable () -> TimeInterval
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "SceneEngine")

    private var bulbs: [Bulb] = []
    private var scene: any LightScene = SceneKind.breathe.makeScene()
    private var palette: Palette = .party
    private var speed: Double = SceneKind.defaultSpeed
    /// Static's single color mode, kept here so switching scene and back does not lose it.
    private var singleColor = false
    private var deduper = ColorDeduper()
    private var sendChain: Task<Void, Never>?

    init(controller: BulbController,
         tickSource: any TickSource,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.controller = controller
        self.tickSource = tickSource
        self.clock = clock
    }

    deinit {
        // The chain is deliberately left alone: the lights out queued by a finished
        // Sunset has to reach the bulbs even if the engine is released straight after.
    }

    // MARK: Lifecycle

    func start(bulbs: [Bulb],
               kind: SceneKind,
               palette: Palette,
               speed: Double,
               singleColor: Bool = false) {
        self.bulbs = bulbs
        self.palette = palette
        self.speed = SceneKind.clampedSpeed(speed)
        self.singleColor = singleColor
        self.scene = kind.makeScene(singleColor: singleColor)
        self.deduper.reset()
        setProgress(nil)
        // Scenes are slow, so the rate limiter is told to expect four sends a second
        // rather than whatever Party Mode last left it set to. Party Mode sets its own
        // rate again on every start, so this cannot strand it at the scene rate.
        let sceneRate = SceneKind.updatesPerSecond
        // Every scene does its brightness in the colors it sends (Breathe's dim base, the
        // Candle's flicker, Sunset's long fade), which only means what it says on a bulb
        // whose own brightness is 100. The Colors pane or the All bulbs slider may have
        // left the room lower, so every bulb is put back first, ahead of the first color,
        // the way Party Mode does. Stopping leaves it there, for the reason Party Mode
        // gives: there is nothing trustworthy to put back.
        let targets = bulbs
        enqueueCommand { controller in
            await controller.setMaxStreamedSendsPerSecond(sceneRate)
            guard !targets.isEmpty else { return }
            await controller.setBrightness(100, bulbs: targets)
        }
        tickSource.start(ticksPerSecond: SceneKind.updatesPerSecond) { [weak self] in
            self?.tick()
        }
        setState(.running(kind))
    }

    /// Stops ticking and leaves the bulbs on the color the scene last sent.
    ///
    /// Deliberately not a settle color. Someone who switches Candle off wanted the room
    /// as it is, not a jump to something else, and spec section 4.4's rule is that
    /// Glowbeat never changes a bulb the user did not ask it to change.
    func stop() {
        guard state != .off else { return }
        tickSource.stop()
        let targets = bulbs
        enqueueCommand { controller in
            await controller.flushStreamed(bulbs: targets)
        }
        setProgress(nil)
        setState(.off)
    }

    // MARK: Live adjustments

    /// Switches to another scene without stopping: the new scene starts from its own
    /// beginning, which is what makes Breathe open at the dim base rather than mid breath.
    func setScene(_ kind: SceneKind) {
        scene = kind.makeScene(singleColor: singleColor)
        deduper.reset()
        setProgress(nil)
        guard state != .off else { return }
        setState(.running(kind))
    }

    /// Static's one color for the whole room. Rebuilds the scene so the change lands on
    /// the next tick; every other scene ignores the flag, so it is safe to set at any time.
    func setSingleColor(_ enabled: Bool) {
        guard singleColor != enabled else { return }
        singleColor = enabled
        guard let kind = state.kind else { return }
        scene = kind.makeScene(singleColor: enabled)
        deduper.reset()
    }

    func setPalette(_ palette: Palette) {
        self.palette = palette
        deduper.reset()
    }

    /// Live, so dragging the Speed slider bends the rest of the scene rather than
    /// restarting it.
    func setSpeed(_ value: Double) {
        speed = SceneKind.clampedSpeed(value)
    }

    func updateBulbs(_ bulbs: [Bulb]) {
        let removed = Set(self.bulbs.map(\.id)).subtracting(bulbs.map(\.id))
        for id in removed {
            deduper.forget(id)
        }
        self.bulbs = bulbs
    }

    // MARK: Internals

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func setProgress(_ newProgress: Double?) {
        guard progress != newProgress else { return }
        progress = newProgress
        onProgressChange?(newProgress)
    }

    /// Runs `work` after every command already queued, so sends land in the order they
    /// were computed.
    private func enqueueCommand(_ work: @escaping @Sendable (BulbController) async -> Void) {
        let previous = sendChain
        sendChain = Task { [controller] in
            await previous?.value
            await work(controller)
        }
    }

    private func tick() {
        guard state != .off else { return }

        let tickTime = Date()
        let now = clock()
        let colors = scene.tick(bulbCount: bulbs.count,
                                palette: palette,
                                speed: speed,
                                time: now)

        var toSend: [(bulb: Bulb, color: GoveeRGB)] = []
        for (index, bulb) in bulbs.enumerated() where index < colors.count {
            guard deduper.shouldSend(colors[index], for: bulb.id) else { continue }
            toSend.append((bulb, FrameBridge.goveeColor(from: colors[index])))
        }

        let sends = toSend
        let targets = bulbs
        enqueueCommand { controller in
            for entry in sends {
                await controller.streamColor(entry.color, to: entry.bulb, at: tickTime)
            }
            await controller.flushStreamed(bulbs: targets, at: tickTime)
        }

        setProgress(scene.progress)
        if scene.isFinished {
            finish()
        }
    }

    /// The end of Sunset: the bulbs go out with a one shot, which is repeated the way
    /// every other deliberate command is, and the Scenes control goes back to off.
    private func finish() {
        tickSource.stop()
        let targets = bulbs
        enqueueCommand { controller in
            await controller.flushStreamed(bulbs: targets)
            await controller.turn(false, bulbs: targets)
        }
        logger.log("A scene reached the end of its timeline and switched the bulbs off.")
        setProgress(nil)
        setState(.off)
    }
}
