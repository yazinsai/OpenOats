import CoreAudio
import Foundation

/// Core Audio property lookups.
enum AudioDevices {
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        value(AudioObjectID(kAudioObjectSystemObject), selector, AudioDeviceID(kAudioObjectUnknown))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static var defaultInput: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutput: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    static func uid(_ device: AudioDeviceID) -> String? {
        value(device, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none)??.takeRetainedValue() as String?
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        value(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }

    /// Devices with at least one input stream, in Core Audio's order.
    static func inputDevices() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr && bytes > 0
        }
    }

    /// The mic to move to after the ones in `stalled` went silent: the default if still usable, then built-in, then
    /// wired, then Bluetooth/other. Never virtual or aggregate devices (Zoom/Teams loopback drivers carry meeting audio).
    static func fallbackMic(excluding stalled: Set<AudioDeviceID>) -> AudioDeviceID? {
        func rank(_ id: AudioDeviceID) -> Int? {
            switch value(id, kAudioDevicePropertyTransportType, UInt32(0)) {
            case kAudioDeviceTransportTypeBuiltIn: 0
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypeThunderbolt: 1
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: nil
            default: 2
            }
        }
        let usable = inputDevices().filter { !stalled.contains($0) && rank($0) != nil }
        if let id = defaultInput, usable.contains(id) { return id }
        return usable.min { rank($0)! < rank($1)! }
    }

    /// Our own process, so the System track leaves out anything we play.
    static func currentProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
