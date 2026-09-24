import XCTest
@testable import AudioTap

final class SystemAudioTapTests: XCTestCase {

    func testANewTapReportsUnknownPermissionAndIsNotRunning() {
        let tap = SystemAudioTap()
        XCTAssertEqual(tap.permission, .unknown)
        XCTAssertFalse(tap.isRunning)
    }

    func testStopOnANeverStartedTapIsSafe() {
        let tap = SystemAudioTap()
        tap.stop()
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 0)
    }

    /// Creating a real tap needs audio hardware and a TCC grant, neither of which exist
    /// in an automated run. Starting is therefore allowed to throw; what must never
    /// happen is a crash, a hang, or a tap left running after `stop()`. A throwing start
    /// is recorded as a skip so the run never reports a silent pass.
    func testStartThenStopLeavesNothingRunning() throws {
        let tap = SystemAudioTap()
        do {
            try tap.start()
        } catch {
            XCTAssertFalse(tap.isRunning)
            XCTAssertEqual(tap.liveCoreAudioObjectCount, 0,
                           "A failing start() must not leak CoreAudio objects.")
            throw XCTSkip("This machine cannot create a process tap: \(error)")
        }
        XCTAssertTrue(tap.isRunning)
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 0)
    }

    func testStartIsIdempotent() throws {
        let tap = SystemAudioTap()
        do {
            try tap.start()
        } catch {
            XCTAssertFalse(tap.isRunning)
            throw XCTSkip("This machine cannot create a process tap: \(error)")
        }
        XCTAssertNoThrow(try tap.start())
        XCTAssertTrue(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 2,
                       "A second start() must not build a second tap and aggregate device.")
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 0)
    }

    /// Two `start()` calls racing each other must not both build a tap: the loser would
    /// have its ids overwritten and its tap left running forever. `liveCoreAudioObjectCount`
    /// counts every CoreAudio object created and not yet destroyed, so a single `stop()`
    /// bringing it back to zero is proof that only one set was ever made.
    func testConcurrentStartsNeverOrphanATap() async throws {
        let tap = SystemAudioTap()
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask { (try? tap.start()) != nil }
            }
            var outcomes: [Bool] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        guard succeeded.allSatisfy({ $0 }) else {
            tap.stop()
            XCTAssertFalse(tap.isRunning)
            XCTAssertEqual(tap.liveCoreAudioObjectCount, 0,
                           "A failing start() must not leak CoreAudio objects.")
            throw XCTSkip("This machine cannot create a process tap.")
        }

        XCTAssertTrue(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 2,
                       "Two concurrent starts built more than one tap and aggregate device.")
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.liveCoreAudioObjectCount, 0)
    }

    func testSystemOutputVolumeIsNilOrInTheUnitRange() throws {
        guard let volume = SystemOutputVolume.current() else {
            throw XCTSkip("The current output device exposes no readable volume control.")
        }
        XCTAssertGreaterThanOrEqual(volume, 0)
        XCTAssertLessThanOrEqual(volume, 1)
    }

    /// Opt in manual smoke test. Not part of the automated run: it needs audio playing
    /// and a TCC grant. Run it with:
    /// `GLOWBEAT_TAP_SMOKE=1 swift test --package-path Packages/AudioTap --filter testSmoke`
    func testSmokeCapturesRealAudioForThreeSeconds() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GLOWBEAT_TAP_SMOKE"] == "1",
                          "Set GLOWBEAT_TAP_SMOKE=1 to run the manual tap smoke test.")

        let tap = SystemAudioTap()
        try tap.start()
        XCTAssertTrue(tap.isRunning)

        let collector = Task { () -> (Int, Float) in
            var count = 0
            var peak: Float = 0
            for await frame in tap.frames {
                count += 1
                peak = max(peak, frame.rms)
            }
            return (count, peak)
        }

        try await Task.sleep(nanoseconds: 3_000_000_000)
        // `stop()` resets the inferred permission, so read it while the tap is live.
        let permissionWhileRunning = tap.permission
        tap.stop()
        // `stop()` deliberately leaves the stream open so the tap can be restarted, so
        // the collector is ended by cancellation rather than by the stream finishing.
        collector.cancel()
        let (count, peak) = await collector.value

        let volume = SystemOutputVolume.current()
        let volumeText = volume.map { "\($0)" } ?? "nil"
        print("SMOKE volume=\(volumeText) frames=\(count) maxRMS=\(peak) "
              + "permission=\(permissionWhileRunning.rawValue)")
        XCTAssertGreaterThan(count, 0, "The tap produced no frames at all in three seconds.")
        XCTAssertGreaterThan(peak, 0, """
            Every captured sample was silent. Either nothing was playing, or macOS is \
            handing out the all zero buffers it gives an app without the system audio \
            recording grant.
            """)
    }
}
