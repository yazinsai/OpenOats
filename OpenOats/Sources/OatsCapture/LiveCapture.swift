import CoreAudio
import Foundation
import IOKit.pwr_mgt
import OatsCore

/// Live capture for the Recorder: the Mic track from the default input device and the System track from a process tap
/// on the default output device. Follows default-device changes (AirPods connect/disconnect) and rebuilds a track that
/// stops delivering, without stopping the recording; the Recorder writes silence over the gap. Keeps the Mac from
/// idle-sleeping while started.
public final class LiveCapture: CaptureSource, @unchecked Sendable {
    /// A track that delivers nothing for this long is rebuilt.
    static let stallAfter: TimeInterval = 4
    private let queue = DispatchQueue(label: "openoats.capture", qos: .userInitiated)
    private let onProblem: @Sendable (String) -> Void
    private lazy var mic = MicCapture(queue: queue)
    private let system = SystemAudioCapture()
    private var deliver: (@Sendable (CapturedAudio) -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: [Track: DispatchWorkItem] = [:]
    private var watchdog: DispatchSourceTimer?
    /// Mics that went silent since the last default-input change; skipped when picking the next one.
    private var stalledMics: Set<AudioDeviceID> = []
    private var lastProblem: [Track: String] = [:]
    private var assertion: IOPMAssertionID = 0

    /// `onProblem` gets trouble that doesn't stop the recording (a mic that can't start, a track that can't be rebuilt),
    /// on a background thread or, for the mic at start, on the caller's.
    public init(onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onProblem = onProblem
    }

    public func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        try queue.sync {
            guard self.deliver == nil else { return }
            self.deliver = deliver
            // A mic that can't start (input mid Bluetooth A2DP ↔ HFP switch) doesn't lose the meeting: record system
            // audio and let the watchdog retry the mic. No system audio is fatal.
            var micProblem: String?
            do { try startMic() } catch { micProblem = error.localizedDescription }
            do { try system.start(deliver) } catch {
                teardown()
                throw error
            }
            if let micProblem {
                lastProblem[.mic] = micProblem
                onProblem(micProblem)
            }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "OpenOats is recording a meeting" as CFString, &assertion)
            listen(kAudioHardwarePropertyDefaultInputDevice) { $0.rebuild(.mic, deviceChanged: true) }
            // The tap is bound to the output device's UID. Output changes (Bluetooth A2DP ↔ HFP) can also silence the
            // mic; rebuilding it here would cost ~0.5 s of speech each time, so the watchdog handles that, with every mic
            // eligible again.
            listen(kAudioHardwarePropertyDefaultOutputDevice) {
                $0.stalledMics = []
                $0.rebuild(.system, deviceChanged: true)
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.checkStalls() }
            timer.resume()
            watchdog = timer
        }
    }

    public func stop() { queue.sync { teardown() } }

    private func teardown() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        listeners = []
        pending.values.forEach { $0.cancel() }
        pending = [:]
        watchdog?.cancel()
        watchdog = nil
        mic.stop()
        system.stop()
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        deliver = nil
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ action: @escaping (LiveCapture) -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self.map(action) }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            listeners.append((address, block))
        }
    }

    /// Rebuilds `track` after a short pause, so a burst of device notifications causes one rebuild.
    private func rebuild(_ track: Track, deviceChanged: Bool) {
        if deviceChanged, track == .mic { stalledMics = [] }
        pending[track]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let deliver else { return }
            pending[track] = nil
            do {
                if track == .mic { try startMic() } else { try system.start(deliver) }
                lastProblem[track] = nil
            } catch {
                // Retried by the watchdog; report each distinct problem once.
                let message = error.localizedDescription
                if lastProblem[track] != message { onProblem(message) }
                lastProblem[track] = message
            }
        }
        pending[track] = item
        queue.asyncAfter(deadline: .now() + (deviceChanged ? 0.5 : 0), execute: item)
    }

    /// CoreAudio can announce a new default device before a Bluetooth device has finished connecting, or a mic can go
    /// silent after an HFP switch, with no further notification. Rebuild whatever stopped delivering. The tap only
    /// delivers while the output device runs, so an idle one isn't stalled; nor is one that never delivered (the
    /// system-audio permission prompt may be up, and Core Audio blocks teardown until it is answered).
    private func checkStalls() {
        if mic.activity.age >= Self.stallAfter, pending[.mic] == nil {
            stalledMics.insert(mic.device)
            rebuild(.mic, deviceChanged: false)
        }
        let outputRunning = AudioDevices.defaultOutput.flatMap { AudioDevices.value($0, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) } == 1
        if system.activity.delivered, system.activity.age >= Self.stallAfter, pending[.system] == nil, outputRunning {
            rebuild(.system, deviceChanged: false)
        }
    }

    private func startMic() throws {
        guard let deliver else { return }
        guard let device = AudioDevices.fallbackMic(excluding: stalledMics) ?? AudioDevices.defaultInput else {
            mic.stop()
            throw CaptureError.noInputDevice
        }
        try mic.start(device: device, deliver)
    }
}
