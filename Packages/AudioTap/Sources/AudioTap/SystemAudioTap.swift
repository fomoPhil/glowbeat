import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

public enum AudioTapError: Error, Equatable {
    case noOutputDevice(OSStatus)
    case deviceUIDUnavailable(OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
}

/// Captures whatever the Mac is playing using a CoreAudio process tap plus a private
/// aggregate device, and publishes analyzed frames.
///
/// Shape follows `docs/research/govee-lan-and-mac-audio-research.md` section 5:
/// `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, a private aggregate device
/// on the built in output, and `AudioDeviceCreateIOProcIDWithBlock`. `AVAudioEngine`
/// cannot be retargeted at a tap backed aggregate device, so the IO proc is used directly.
///
/// Teardown order is mandatory: stop, destroy the IO proc, destroy the aggregate device,
/// destroy the tap.
///
/// Marked `@unchecked Sendable`. The confinement discipline is:
/// - `controlLock` serializes the whole body of `start()` and `stop()`, so the two can
///   never interleave and two concurrent `start()` calls can never both build a tap.
/// - `lock` guards the CoreAudio ids, the permission state, the cached output volume, the
///   volume timer and the live object count. It is held for a few instructions at a time
///   and is the only lock the realtime IO queue ever takes.
/// - Lock ordering is always `controlLock` then `lock`, never the reverse, and `lock` is
///   never held across `AudioDeviceStart`, `AudioDeviceStop` or a hop to `ioQueue`.
/// - `mapper`, `monoScratch`, `formatChannelCount`, `silentFrameCount`, `deniedLatched`
///   and the two log once flags are touched only on `ioQueue`, the serial queue CoreAudio
///   runs the IO block on. `start()` and `stop()` reach them through `onIOQueue`.
/// - The IO path makes no HAL calls at all. The system output volume is sampled off the
///   IO queue by a 1 Hz timer and read from `cachedOutputVolume`.
/// - The two `AsyncStream` continuations are themselves `Sendable` and safe from any
///   thread.
public final class SystemAudioTap: AudioFrameSource, @unchecked Sendable {

    /// Below this RMS a frame counts as pure digital silence.
    private static let silenceThreshold: Float = 1e-5

    public nonisolated let frames: AsyncStream<AudioFrame>
    public nonisolated let permissionUpdates: AsyncStream<AudioTapPermission>

    private nonisolated let framesContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let permissionContinuation: AsyncStream<AudioTapPermission>.Continuation

    private let framesPerSecond: Int
    private let silentFramesBeforeDenied: Int
    private let controlLock = NSLock()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.philwoolley.glowbeat.audiotap",
                                        qos: .userInitiated)
    private let ioQueueKey = DispatchSpecificKey<Void>()
    private let volumeQueue = DispatchQueue(label: "com.philwoolley.glowbeat.audiotap.volume",
                                            qos: .utility)
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "SystemAudioTap")

    // Guarded by `lock`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var permissionState: AudioTapPermission = .unknown
    private var cachedOutputVolume: Float?
    private var volumeTimer: DispatchSourceTimer?
    /// Every CoreAudio object this tap has created and not yet destroyed. Tests assert it
    /// returns to zero, which catches both leaks on a failing `start()` and an orphaned
    /// tap from two concurrent starts.
    private var liveObjectCount = 0

    // Touched only on `ioQueue`.
    private var mapper: BandMapper?
    private var monoScratch = [Float](repeating: 0, count: 16_384)
    private var formatChannelCount = 0
    private var silentFrameCount = 0
    private var deniedLatched = false
    private var loggedUnexpectedLayout = false
    private var loggedChannelMismatch = false

    public init(framesPerSecond: Int = 50, silenceSecondsBeforeDenied: Double = 3) {
        self.framesPerSecond = max(1, framesPerSecond)
        self.silentFramesBeforeDenied = max(1, Int(Double(max(1, framesPerSecond))
                                                   * max(0.5, silenceSecondsBeforeDenied)))
        let frameStream = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(120))
        self.frames = frameStream.stream
        self.framesContinuation = frameStream.continuation
        let permissionStream = AsyncStream<AudioTapPermission>
            .makeStream(bufferingPolicy: .bufferingNewest(4))
        self.permissionUpdates = permissionStream.stream
        self.permissionContinuation = permissionStream.continuation
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    /// Prefer calling `stop()` explicitly before releasing the last reference. Deinit is a
    /// backstop: it can run on `ioQueue` (see `onIOQueue`), and tearing a running device
    /// down from inside an IO callback is a place CoreAudio would rather not be.
    deinit {
        stop()
        framesContinuation.finish()
        permissionContinuation.finish()
    }

    public var permission: AudioTapPermission {
        lock.lock()
        defer { lock.unlock() }
        return permissionState
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ioProcID != nil
    }

    /// CoreAudio objects created and not yet destroyed. Test only.
    var liveCoreAudioObjectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveObjectCount
    }

    public func start() throws {
        // Held for the whole body: without it two concurrent calls both pass the guard
        // below and the second overwrites the first's ids, orphaning a running tap.
        controlLock.lock()
        defer { controlLock.unlock() }

        lock.lock()
        let alreadyRunning = ioProcID != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let outputDevice = try Self.builtInOrDefaultOutputDevice()
        let outputUID = try Self.deviceUID(outputDevice)

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.currentProcessObjectID().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Glowbeat System Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw failed(.tapCreationFailed(tapStatus))
        }
        countObject(+1)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Glowbeat Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]

        var newAggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            destroyTap(newTapID)
            throw failed(.aggregateDeviceCreationFailed(aggregateStatus))
        }
        countObject(+1)

        // Never assume 48 kHz stereo float: read what the tap actually produces.
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let formatStatus = AudioObjectGetPropertyData(newTapID, &formatAddress, 0, nil,
                                                      &formatSize, &format)
        let isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        guard formatStatus == noErr,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0,
              isFloat32 else {
            destroyAggregate(newAggregateID)
            destroyTap(newTapID)
            throw failed(.tapFormatUnavailable(formatStatus))
        }

        let newMapper = BandMapper(sampleRate: format.mSampleRate,
                                   framesPerSecond: framesPerSecond)
        let channels = Int(format.mChannelsPerFrame)

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, newAggregateID, ioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.handleInput(inputData)
        }
        guard procStatus == noErr, let procID = newProcID else {
            destroyAggregate(newAggregateID)
            destroyTap(newTapID)
            throw failed(.ioProcCreationFailed(procStatus))
        }

        // The IO block only runs once `AudioDeviceStart` succeeds, so the analysis state
        // is handed to `ioQueue` here, immediately before starting.
        onIOQueue {
            mapper = newMapper
            formatChannelCount = channels
            resetSilenceTracking()
        }
        // Seed the cached volume before any frame can need it: the IO path must never
        // call into the HAL itself.
        refreshOutputVolume()

        // The system audio permission prompt fires here, not at tap creation.
        let startStatus = AudioDeviceStart(newAggregateID, procID)
        guard startStatus == noErr else {
            onIOQueue {
                mapper = nil
                resetSilenceTracking()
            }
            check(AudioDeviceDestroyIOProcID(newAggregateID, procID),
                  "AudioDeviceDestroyIOProcID")
            destroyAggregate(newAggregateID)
            destroyTap(newTapID)
            throw failed(.deviceStartFailed(startStatus))
        }

        let timer = DispatchSource.makeTimerSource(queue: volumeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refreshOutputVolume() }
        timer.resume()

        lock.lock()
        tapID = newTapID
        aggregateID = newAggregateID
        ioProcID = procID
        permissionState = .unknown
        volumeTimer = timer
        lock.unlock()
        permissionContinuation.yield(.unknown)
        logger.info("""
            System audio tap started at \(format.mSampleRate, privacy: .public) Hz, \
            \(channels, privacy: .public) channels
            """)
    }

    public func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }

        lock.lock()
        let procID = ioProcID
        let aggregate = aggregateID
        let tap = tapID
        let timer = volumeTimer
        let permissionChanged = permissionState != .unknown
        ioProcID = nil
        aggregateID = AudioDeviceID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        volumeTimer = nil
        permissionState = .unknown
        cachedOutputVolume = nil
        lock.unlock()

        timer?.cancel()

        if let procID, aggregate != kAudioObjectUnknown {
            check(AudioDeviceStop(aggregate, procID), "AudioDeviceStop")
            check(AudioDeviceDestroyIOProcID(aggregate, procID), "AudioDeviceDestroyIOProcID")
        }
        if aggregate != kAudioObjectUnknown {
            destroyAggregate(aggregate)
        }
        if tap != kAudioObjectUnknown {
            destroyTap(tap)
        }

        // Safe to touch the analysis state now: the IO proc was stopped above, so the IO
        // block can no longer run and there is nothing left to race.
        onIOQueue {
            mapper = nil
            resetSilenceTracking()
        }

        // Keep `permissionUpdates` consistent with `permission`, which this reset changed.
        if permissionChanged {
            permissionContinuation.yield(.unknown)
        }
    }

    // MARK: Queue and lock helpers

    /// Runs `work` on `ioQueue`, inline when already there.
    ///
    /// `deinit` can legitimately run on `ioQueue`: the IO block's `self?` takes a
    /// temporary strong reference, so if the last external reference drops while a
    /// callback is in flight, deallocation happens on that queue. `ioQueue.sync` from
    /// `ioQueue` would deadlock, hence the check.
    private func onIOQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            work()
        } else {
            ioQueue.sync(execute: work)
        }
    }

    /// Called only on `ioQueue`.
    private func resetSilenceTracking() {
        silentFrameCount = 0
        deniedLatched = false
    }

    private func refreshOutputVolume() {
        let volume = SystemOutputVolume.current()
        lock.lock()
        cachedOutputVolume = volume
        lock.unlock()
    }

    private func countObject(_ delta: Int) {
        lock.lock()
        liveObjectCount += delta
        lock.unlock()
    }

    private func destroyTap(_ tap: AudioObjectID) {
        check(AudioHardwareDestroyProcessTap(tap), "AudioHardwareDestroyProcessTap")
        countObject(-1)
    }

    private func destroyAggregate(_ aggregate: AudioDeviceID) {
        check(AudioHardwareDestroyAggregateDevice(aggregate),
              "AudioHardwareDestroyAggregateDevice")
        countObject(-1)
    }

    private func check(_ status: OSStatus, _ call: String) {
        guard status != noErr else { return }
        logger.error("\(call, privacy: .public) returned \(status, privacy: .public)")
    }

    private func failed(_ error: AudioTapError) -> AudioTapError {
        logger.error("""
            System audio tap could not start: \(String(describing: error), privacy: .public)
            """)
        return error
    }

    // MARK: CoreAudio IO thread

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let mapper else { return }
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard list.count > 0 else { return }

        // Each buffer carries `mNumberChannels` interleaved channels: a non interleaved
        // tap sends one single channel buffer per channel, an interleaved one sends a
        // single buffer holding them all. Frame counts are therefore computed per buffer
        // and the shortest wins, so no buffer is ever read past its end.
        let bytesPerSample = MemoryLayout<Float>.size
        var frameCount = Int.max
        var totalChannels = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mData != nil else {
                logUnexpectedLayoutOnce(list.count)
                return
            }
            frameCount = min(frameCount,
                             Int(buffer.mDataByteSize) / (bytesPerSample * channels))
            totalChannels += channels
        }
        guard totalChannels > 0, frameCount > 0, frameCount <= monoScratch.count else { return }
        if totalChannels != formatChannelCount, !loggedChannelMismatch {
            loggedChannelMismatch = true
            logger.info("""
                Tap delivered \(totalChannels, privacy: .public) channels, \
                the tap format says \(self.formatChannelCount, privacy: .public)
                """)
        }

        for index in 0..<frameCount {
            monoScratch[index] = 0
        }
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            if channels == 1 {
                for index in 0..<frameCount {
                    monoScratch[index] += data[index]
                }
            } else {
                for index in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += data[index * channels + channel]
                    }
                    monoScratch[index] += sum
                }
            }
        }

        var scale = 1 / Float(totalChannels)
        monoScratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frameCount))
        }

        let time = ProcessInfo.processInfo.systemUptime
        monoScratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            mapper.process(base, count: frameCount, time: time) { [weak self] frame in
                self?.emit(frame)
            }
        }
    }

    /// Called only on `ioQueue`.
    private func logUnexpectedLayoutOnce(_ bufferCount: Int) {
        guard !loggedUnexpectedLayout else { return }
        loggedUnexpectedLayout = true
        logger.error("""
            Dropping tap buffers: unexpected layout in \
            \(bufferCount, privacy: .public) buffers
            """)
    }

    /// Called only on `ioQueue`, so the silence tracking needs no lock. Makes no HAL
    /// calls: the output volume comes from the cache the 1 Hz timer refreshes.
    private func emit(_ frame: AudioFrame) {
        framesContinuation.yield(frame)

        guard frame.rms < Self.silenceThreshold else {
            resetSilenceTracking()
            setPermission(.granted)
            return
        }
        if silentFrameCount < silentFramesBeforeDenied {
            silentFrameCount += 1
        }
        // macOS returns success even when capture is denied, so denial is inferred from a
        // long run of pure silence while the output volume is up. The decision is latched
        // once per silent run and released as soon as audio appears.
        guard !deniedLatched, silentFrameCount >= silentFramesBeforeDenied else { return }
        lock.lock()
        let volume = cachedOutputVolume
        lock.unlock()
        // An unreadable volume, common on aggregate and virtual devices, counts as up.
        guard (volume ?? 1) > 0.001 else { return }
        deniedLatched = true
        setPermission(.deniedOrSilent)
    }

    private func setPermission(_ newValue: AudioTapPermission) {
        lock.lock()
        let changed = permissionState != newValue
        permissionState = newValue
        lock.unlock()
        guard changed else { return }
        permissionContinuation.yield(newValue)
    }

    // MARK: CoreAudio helpers

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                UInt32(MemoryLayout<pid_t>.size),
                                                &pid,
                                                &size,
                                                &objectID)
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    /// Prefers the built in output, because the default output changes when AirPods
    /// connect and the aggregate device would then follow them.
    private static func builtInOrDefaultOutputDevice() throws -> AudioObjectID {
        if let builtIn = builtInOutputDevice() { return builtIn }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioTapError.noOutputDevice(status)
        }
        return device
    }

    private static func builtInOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        for device in devices {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil,
                                             &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else {
                continue
            }
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil,
                                                 &streamSize) == noErr, streamSize > 0 else {
                continue
            }
            return device
        }
        return nil
    }

    private static func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw AudioTapError.deviceUIDUnavailable(status) }
        return uid as String
    }
}
