import CoreAudio
import Foundation

/// Reads the system output volume, used only to tell "denied" apart from "nothing is
/// playing". Returns nil when the current output device has no readable volume control,
/// which is common on aggregate and virtual devices.
public enum SystemOutputVolume {

    public static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        if AudioObjectHasProperty(device, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // Some devices only expose per channel volume.
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(device, &channelAddress) else { continue }
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &channelAddress, 0, nil,
                                          &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
