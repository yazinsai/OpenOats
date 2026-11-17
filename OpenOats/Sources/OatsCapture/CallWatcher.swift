import CoreAudio
import CoreMediaIO
import Foundation
import OatsCore

/// Reports Calls from Core Audio's per-process state. Costs nothing while no mic is in use: input devices wake it,
/// then it samples the audio clients (and whether a camera is on) every 2 s until the mic is free and no Call is left
/// open. Reads only who is using audio and whether a camera runs, never audio or video, so it needs no permission.
public final class CallWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openoats.calls", qos: .utility)
    private let onEvent: @Sendable (CallEvent) -> Void
    private var detector = CallDetector()
    private var devices: [AudioDeviceID] = []
    private var sampling = false
    private var running = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.wake() }
    private static let interval: TimeInterval = 2

    public init(onEvent: @escaping @Sendable (CallEvent) -> Void) { self.onEvent = onEvent }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            wake()
        }
    }

    /// Calls in progress are dropped without an `ended` event.
    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            watch([])
            detector = CallDetector()
        }
    }

    /// A device appeared or started/stopped somewhere: follow the device list, and sample if not already.
    private func wake() {
        guard running else { return }
        watch(AudioDevices.inputDevices())
        guard !sampling else { return }
        sampling = true
        sample()
    }

    private func watch(_ now: [AudioDeviceID]) {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for id in devices where !now.contains(id) { AudioObjectRemovePropertyListenerBlock(id, &address, queue, listener) }
        for id in now where !devices.contains(id) { AudioObjectAddPropertyListenerBlock(id, &address, queue, listener) }
        devices = now
    }

    private func sample() {
        guard running else { return sampling = false }
        let clients = Self.audioClients()
        for event in detector.update(clients, cameraOn: Self.cameraOn(), at: Date()) { onEvent(event) }
        guard clients.contains(where: \.input) || detector.isTracking else { return sampling = false }
        queue.asyncAfter(deadline: .now() + Self.interval) { [weak self] in self?.sample() }
    }

    /// Every other process with a running input or output stream (macOS 14 process objects).
    public static func audioClients() -> [AudioClient] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = getpid()
        return objects.compactMap { object in
            let input = (AudioDevices.value(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0
            let output = (AudioDevices.value(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            guard input || output, AudioDevices.value(object, kAudioProcessPropertyPID, pid_t(0)) != me else { return nil }
            let bundleID = AudioDevices.value(object, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none)??
                .takeRetainedValue() as String?
            return AudioClient(bundleID: bundleID ?? "", input: input, output: output)
        }
    }

    /// Whether any camera is in use by any process (CoreMediaIO; which process isn't exposed).
    public static func cameraOn() -> Bool {
        func address(_ selector: Int) -> CMIOObjectPropertyAddress {
            CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        }
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var devices = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &devices, 0, nil, size, &used, &ids) == noErr else { return false }
        return ids.contains { id in
            var running = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var value: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
                && value != 0
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
