import XCTest
@testable import Effects

/// The non-music modes. Every one of these is a pure value type driven by a clock the
/// test supplies, so a twenty minute sunset takes no longer to prove than a breath does.
final class SceneTests: XCTestCase {

    private let palette = Palette.party

    /// Drives a scene at the rate the engine runs it, and hands back every frame.
    private func run(_ scene: inout some LightScene,
                     bulbCount: Int,
                     seconds: TimeInterval,
                     speed: Double = 1,
                     palette: Palette? = nil) -> [[RGB]] {
        let step = 1.0 / Double(SceneKind.updatesPerSecond)
        var frames: [[RGB]] = []
        var time: TimeInterval = 0
        while time <= seconds {
            frames.append(scene.tick(bulbCount: bulbCount,
                                     palette: palette ?? self.palette,
                                     speed: speed,
                                     time: time))
            time += step
        }
        return frames
    }

    // MARK: The kind

    func testEveryKindBuildsTheSceneItNames() {
        for kind in SceneKind.allCases {
            XCTAssertEqual(kind.makeScene().kind, kind)
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.summary.isEmpty)
        }
        XCTAssertEqual(SceneKind.allCases.count, 5)
        XCTAssertEqual(SceneKind(rawValue: "static"), .fixed)
    }

    func testOnlySunsetHasATimeline() {
        for kind in SceneKind.allCases {
            XCTAssertEqual(kind.hasTimeline, kind == .sunset, kind.displayName)
        }
    }

    func testTheSpeedIsClampedToAQuarterThroughFour() {
        XCTAssertEqual(SceneKind.clampedSpeed(0), 0.25)
        XCTAssertEqual(SceneKind.clampedSpeed(99), 4)
        XCTAssertEqual(SceneKind.clampedSpeed(1.5), 1.5)
        XCTAssertEqual(SceneKind.defaultSpeed, 1)
    }

    func testEverySceneFillsEveryBulbAndHandlesNone() {
        for kind in SceneKind.allCases {
            var scene = kind.makeScene()
            let colors = scene.tick(bulbCount: 3, palette: palette, speed: 1, time: 0)
            XCTAssertEqual(colors.count, 3, kind.displayName)
            XCTAssertTrue(scene.tick(bulbCount: 0, palette: palette, speed: 1, time: 1).isEmpty,
                          kind.displayName)
        }
    }

    /// An empty palette is not reachable through the picker, but a scene must not crash
    /// on one either.
    func testEverySceneSurvivesAPaletteWithNoColors() {
        let empty = Palette(id: "empty", name: "Empty", colors: [], dimBase: .black)
        for kind in SceneKind.allCases {
            var scene = kind.makeScene()
            let colors = scene.tick(bulbCount: 2, palette: empty, speed: 1, time: 0)
            XCTAssertEqual(colors.count, 2, kind.displayName)
        }
    }

    // MARK: Breathe

    func testBreatheStartsLitAndDipsHalfwayThroughTheBreath() {
        var scene = BreatheScene()
        let frames = run(&scene, bulbCount: 2, seconds: BreatheScene.breathDuration)
        XCTAssertEqual(frames.first, [palette.colors[0], palette.colors[0]],
                       "Switching the scene on in a lit room must not drop it first.")

        let dip = frames[frames.count / 2]
        XCTAssertEqual(Set(dip).count, 1, "Every bulb breathes together.")
        XCTAssertEqual(dip[0], palette.dimBase)

        let quarter = frames[frames.count / 4]
        XCTAssertGreaterThan(quarter[0].luminance, dip[0].luminance)
        XCTAssertLessThan(quarter[0].luminance, frames[0][0].luminance,
                          "The breath has to be on its way down a quarter of the way in.")
    }

    func testBreatheTakesTheNextPaletteColorEachBreath() {
        var scene = BreatheScene()
        var tops: [RGB] = []
        for breath in 0..<3 {
            let start = Double(breath) * BreatheScene.breathDuration
            // Every breath opens at the top of its own color, so that is where to read it.
            var time = breath == 0 ? 0 : start - BreatheScene.breathDuration / 2
            var frame: [RGB] = []
            while time <= start {
                frame = scene.tick(bulbCount: 1, palette: palette, speed: 1, time: time)
                time += 1.0 / Double(SceneKind.updatesPerSecond)
            }
            tops.append(frame[0])
        }
        XCTAssertEqual(tops, Array(palette.colors.prefix(3)))
    }

    func testDoubleSpeedTakesHalfAsLongToBreathe() {
        var fast = BreatheScene()
        let frames = run(&fast, bulbCount: 1, seconds: BreatheScene.breathDuration / 2, speed: 2)
        XCTAssertEqual(frames[frames.count / 2][0], palette.dimBase,
                       "At 2x the breath reaches its dip in half the time.")
        XCTAssertEqual(frames[frames.count - 1][0], palette.colors[1],
                       "And a whole breath, and the next color, in half the time.")
    }

    // MARK: Color flow

    func testColorFlowLaysThePaletteAlongTheBulbsAndMovesItOneBulbPerStep() {
        var scene = ColorFlowScene()
        let first = scene.tick(bulbCount: 3, palette: palette, speed: 1, time: 0)
        XCTAssertEqual(first, Array(palette.colors.prefix(3)))

        // One whole step later the pattern has moved one bulb along the list.
        let moved = scene.tick(bulbCount: 3,
                               palette: palette,
                               speed: 1,
                               time: ColorFlowScene.stepDuration)
        XCTAssertEqual(moved, [palette.colors[palette.colors.count - 1],
                               palette.colors[0],
                               palette.colors[1]])
    }

    func testColorFlowCrossfadesBetweenTheSteps() {
        var scene = ColorFlowScene()
        _ = scene.tick(bulbCount: 1, palette: palette, speed: 1, time: 0)
        let midway = scene.tick(bulbCount: 1,
                                palette: palette,
                                speed: 1,
                                time: ColorFlowScene.stepDuration / 2)[0]
        XCTAssertGreaterThan(midway.channelDistance(to: palette.colors[0]), 0)
        XCTAssertGreaterThan(midway.channelDistance(to: palette.colors[palette.colors.count - 1]), 0)
    }

    func testColorFlowWrapsWhenThereAreMoreBulbsThanColors() {
        var scene = ColorFlowScene()
        let colors = scene.tick(bulbCount: palette.colors.count + 2,
                                palette: palette,
                                speed: 1,
                                time: 0)
        XCTAssertEqual(colors[palette.colors.count], palette.colors[0])
        XCTAssertEqual(colors[palette.colors.count + 1], palette.colors[1])
    }

    // MARK: Candle

    func testCandleIsDeterministicForASeed() {
        var first = CandleScene(generator: SeededGenerator(seed: 42))
        var second = CandleScene(generator: SeededGenerator(seed: 42))
        XCTAssertEqual(run(&first, bulbCount: 3, seconds: 10),
                       run(&second, bulbCount: 3, seconds: 10))

        var other = CandleScene(generator: SeededGenerator(seed: 7))
        XCTAssertNotEqual(run(&first, bulbCount: 3, seconds: 10),
                          run(&other, bulbCount: 3, seconds: 10))
    }

    func testCandleStaysBetweenFortyAndOneHundredPercentOfTheFlame() {
        var scene = CandleScene(generator: SeededGenerator(seed: 1))
        let frames = run(&scene, bulbCount: 4, seconds: 120)
        let darkest = CandleScene.flame.scaled(by: CandleScene.minimumBrightness)
        for frame in frames {
            for color in frame {
                XCTAssertGreaterThanOrEqual(Int(color.r), Int(darkest.r) - 1)
                XCTAssertLessThanOrEqual(Int(color.r), Int(CandleScene.flame.r))
                // The hue never moves, only the brightness.
                XCTAssertLessThanOrEqual(Int(color.b), Int(CandleScene.flame.b))
            }
        }
    }

    /// A free random walk spends most of its time pinned to a rail. This one is pulled
    /// back, so over a long run the room sits around its resting brightness.
    func testTheCandleWalkIsPulledBackTowardItsRestingBrightness() {
        var scene = CandleScene(generator: SeededGenerator(seed: 11))
        let frames = run(&scene, bulbCount: 4, seconds: 300)
        let brightnesses = frames.dropFirst().flatMap { frame in
            frame.map { Double($0.r) / Double(CandleScene.flame.r) }
        }
        let mean = brightnesses.reduce(0, +) / Double(brightnesses.count)
        XCTAssertEqual(mean, CandleScene.restingBrightness, accuracy: 0.1,
                       "The flicker has to sit around its resting brightness.")

        let atARail = brightnesses.filter {
            $0 <= CandleScene.minimumBrightness + 0.001
                || $0 >= CandleScene.maximumBrightness - 0.001
        }
        XCTAssertLessThan(Double(atARail.count) / Double(brightnesses.count), 0.1,
                          "A flame pinned to a rail reads as a fault, not as a candle.")
    }

    /// One tick may only move a bulb so far, or the flicker strobes.
    func testOneTickNeverMovesACandleMoreThanAQuarterOfItsRange() {
        var scene = CandleScene(generator: SeededGenerator(seed: 5))
        let frames = run(&scene, bulbCount: 3, seconds: 60)
        // The walk plus the pull, in channel terms, with one step of rounding slack.
        let range = CandleScene.maximumBrightness - CandleScene.minimumBrightness
        let limit = Double(CandleScene.flame.r) * range
            * (CandleScene.maximumStepFraction + CandleScene.reversionRate) + 1
        for (previous, next) in zip(frames, frames.dropFirst()) {
            for (before, after) in zip(previous, next) {
                XCTAssertLessThanOrEqual(abs(Int(after.r) - Int(before.r)), Int(limit.rounded()))
            }
        }
    }

    /// The walk is measured in scene seconds, so the same stretch of scene time produces
    /// the same amount of flicker however the ticks happen to fall.
    func testTheFlickerFollowsSceneTimeRatherThanTickCount() {
        var slow = CandleScene(generator: SeededGenerator(seed: 21))
        var fast = CandleScene(generator: SeededGenerator(seed: 21))
        // Ten seconds of scene time each: one at 1x over ten seconds of clock, one at 4x
        // over two and a half.
        let atOne = run(&slow, bulbCount: 2, seconds: 10, speed: 1).last
        let atFour = run(&fast, bulbCount: 2, seconds: 2.5, speed: 4).last
        XCTAssertNotNil(atOne)
        XCTAssertNotNil(atFour)
        let oneSpan = spread(of: run(&slow, bulbCount: 2, seconds: 60, speed: 1))
        let fourSpan = spread(of: run(&fast, bulbCount: 2, seconds: 15, speed: 4))
        XCTAssertEqual(oneSpan, fourSpan, accuracy: 0.25,
                       "Four times the speed over a quarter of the time is the same flicker.")
    }

    /// How far the brightest and dimmest frames of a run are apart, 0 through 1.
    private func spread(of frames: [[RGB]]) -> Double {
        let values = frames.flatMap { $0.map { Double($0.r) / Double(CandleScene.flame.r) } }
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    func testEachCandleFlickersOnItsOwn() {
        var scene = CandleScene(generator: SeededGenerator(seed: 3))
        let frames = run(&scene, bulbCount: 4, seconds: 20)
        XCTAssertTrue(frames.contains { Set($0).count > 1 },
                      "A room of candles must not dip all at once.")
    }

    // MARK: Sunset

    func testSunsetRunsTwentyMinutesAndEndsDeepAndDim() {
        var scene = SunsetScene()
        XCTAssertEqual(scene.progress, 0)
        let opening = scene.tick(bulbCount: 2, palette: palette, speed: 1, time: 0)
        XCTAssertEqual(opening, [SunsetScene.warmWhite, SunsetScene.warmWhite])
        XCTAssertFalse(scene.isFinished)

        let halfway = scene.tick(bulbCount: 1,
                                 palette: palette,
                                 speed: 1,
                                 time: SunsetScene.duration / 2)[0]
        XCTAssertEqual(scene.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertLessThan(halfway.luminance, SunsetScene.warmWhite.luminance)
        XCTAssertFalse(scene.isFinished)

        let end = scene.tick(bulbCount: 1,
                             palette: palette,
                             speed: 1,
                             time: SunsetScene.duration)[0]
        XCTAssertEqual(scene.progress ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(scene.isFinished, "The scene has to tell the engine it is over.")
        XCTAssertLessThan(end.luminance, halfway.luminance)
        XCTAssertEqual(end,
                       SunsetScene.deepOrange.scaled(by: SunsetScene.finalBrightness))
    }

    func testSunsetAtFourTimesSpeedFinishesInFiveMinutes() {
        var scene = SunsetScene()
        _ = scene.tick(bulbCount: 1, palette: palette, speed: 4, time: 0)
        _ = scene.tick(bulbCount: 1, palette: palette, speed: 4, time: 5 * 60)
        XCTAssertTrue(scene.isFinished)
        XCTAssertEqual(scene.progress ?? 0, 1, accuracy: 0.0001)
    }

    func testOnlySunsetReportsProgress() {
        for kind in SceneKind.allCases where kind != .sunset {
            var scene = kind.makeScene()
            _ = scene.tick(bulbCount: 1, palette: palette, speed: 1, time: 0)
            XCTAssertNil(scene.progress, kind.displayName)
            XCTAssertFalse(scene.isFinished, kind.displayName)
        }
    }

    func testResetPutsASunsetBackAtTheStart() {
        var scene = SunsetScene()
        _ = scene.tick(bulbCount: 1, palette: palette, speed: 1, time: 0)
        _ = scene.tick(bulbCount: 1, palette: palette, speed: 1, time: SunsetScene.duration)
        XCTAssertTrue(scene.isFinished)
        scene.reset()
        XCTAssertFalse(scene.isFinished)
        XCTAssertEqual(scene.progress, 0)
    }

    // MARK: Static

    func testStaticHoldsOnePaletteColorPerBulbAndNeverMoves() {
        var scene = StaticScene()
        let frames = run(&scene, bulbCount: 7, seconds: 30, speed: 4)
        let expected = (0..<7).map { palette.colors[$0 % palette.colors.count] }
        for frame in frames {
            XCTAssertEqual(frame, expected)
        }
    }

    /// Single color mode: one color for the whole room, whatever the palette holds.
    func testSingleColorModePutsTheFirstPaletteColorOnEveryBulb() {
        var scene = StaticScene(singleColor: true)
        let colors = scene.tick(bulbCount: 5, palette: palette, speed: 1, time: 0)
        XCTAssertEqual(colors, Array(repeating: palette.colors[0], count: 5))

        var spread = StaticScene(singleColor: false)
        XCTAssertNotEqual(spread.tick(bulbCount: 5, palette: palette, speed: 1, time: 0),
                          colors,
                          "Off, the palette is spread across the bulbs again.")
    }

    func testOnlyStaticHasASingleColorModeAndTheFactoryPassesItOn() {
        for kind in SceneKind.allCases {
            XCTAssertEqual(kind.hasSingleColorMode, kind == .fixed, kind.displayName)
            // Every other scene has to ignore the flag rather than refuse it.
            XCTAssertEqual(kind.makeScene(singleColor: true).kind, kind)
        }
        var single = SceneKind.fixed.makeScene(singleColor: true)
        XCTAssertEqual(Set(single.tick(bulbCount: 3, palette: palette, speed: 1, time: 0)).count, 1)
    }

    /// A palette with one color in it lands on every bulb whether or not the switch is on.
    func testAPaletteOfOneColorPutsThatColorOnEveryBulb() {
        let single = Palette(id: "one", name: "One",
                             colors: [RGB(hex: 0x00FF00)], dimBase: .black)
        var scene = StaticScene()
        let colors = scene.tick(bulbCount: 4, palette: single, speed: 1, time: 0)
        XCTAssertEqual(colors, Array(repeating: RGB(hex: 0x00FF00), count: 4))
    }
}
