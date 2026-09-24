import AudioTap
import Foundation

/// Feeds the engine a scripted sequence of audio frames with no audio hardware.
final class ScriptedFrameSource: AudioFrameSource, @unchecked Sendable {

    let frames: AsyncStream<AudioTap.AudioFrame>
    let permissionUpdates: AsyncStream<AudioTapPermission>

    private let framesContinuation: AsyncStream<AudioTap.AudioFrame>.Continuation
    private let permissionContinuation: AsyncStream<AudioTapPermission>.Continuation
    private let lock = NSLock()
    private var running = false
    private var startDelay: TimeInterval = 0
    private var startThreadWasMain: Bool?
    private var permissionOnStart: AudioTapPermission = .granted
    private var startError: (any Error)?

    init() {
        let frameStream = AsyncStream<AudioTap.AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1000))
        frames = frameStream.stream
        framesContinuation = frameStream.continuation
        let permissionStream = AsyncStream<AudioTapPermission>.makeStream(
            bufferingPolicy: .bufferingNewest(8))
        permissionUpdates = permissionStream.stream
        permissionContinuation = permissionStream.continuation
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Makes `start()` take as long as a real Core Audio tap does to build.
    func setStartDelay(_ seconds: TimeInterval) {
        lock.lock()
        startDelay = seconds
        lock.unlock()
    }

    /// What `start()` reports once the tap is open. `.granted` by default, which is a tap
    /// that hears music straight away. `.unknown` is what `SystemAudioTap` really reports
    /// when it opens: it says nothing more until a frame is audible or three seconds of
    /// silence have gone by, so a session that never hears anything starts here.
    func setPermissionOnStart(_ permission: AudioTapPermission) {
        lock.lock()
        permissionOnStart = permission
        lock.unlock()
    }

    /// Makes every later `start()` throw, the way a tap that will not open does. Nil opens
    /// normally again.
    func setStartError(_ error: (any Error)?) {
        lock.lock()
        startError = error
        lock.unlock()
    }

    /// Whether the last `start()` ran on the main thread. Nil before the first start.
    var startRanOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return startThreadWasMain
    }

    func start() throws {
        let wasMain = Thread.isMainThread
        lock.lock()
        let delay = startDelay
        let error = startError
        let permission = permissionOnStart
        lock.unlock()
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if let error {
            throw error
        }
        lock.lock()
        running = true
        startThreadWasMain = wasMain
        lock.unlock()
        permissionContinuation.yield(permission)
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Simulates the tap inferring a permission state, which it does from the audio
    /// itself rather than from any API.
    func emitPermission(_ permission: AudioTapPermission) {
        permissionContinuation.yield(permission)
    }

    func emit(_ frame: AudioTap.AudioFrame) {
        framesContinuation.yield(frame)
    }

    /// Emits `frameCount` frames at 50 fps with the bass band bursting every
    /// `burstEvery` frames. Matches the metronome fixture used in the Effects tests.
    func emitMetronome(frameCount: Int, burstEvery: Int = 25, startTime: TimeInterval = 0) {
        for index in 0..<frameCount {
            let isBurst = index >= 25 && index % burstEvery <= 1
            let bass: Float = isBurst ? 0.9 : 0.1
            emit(AudioTap.AudioFrame(time: startTime + Double(index) / 50,
                                     rms: isBurst ? 0.9 : 0.1,
                                     bands: [0.05, bass, 0.05, 0.05, 0.05]))
        }
    }

    func emitSilence(frameCount: Int, startTime: TimeInterval = 0) {
        for index in 0..<frameCount {
            emit(AudioTap.AudioFrame(time: startTime + Double(index) / 50,
                                     rms: 0,
                                     bands: [0, 0, 0, 0, 0]))
        }
    }
}
