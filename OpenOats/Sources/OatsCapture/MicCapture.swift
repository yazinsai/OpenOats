@preconcurrency import AVFoundation
import CoreAudio
import OatsCore

/// The Mic track: an AVAudioEngine input tap on one device. Used on the LiveCapture queue only.
final class MicCapture: @unchecked Sendable {
    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    /// AVAudioEngine teardown races AVAudioIOUnit callbacks during route changes (AirPods); keep recently
    /// stopped engines alive so AVFAudio's internal queues can drain.
    private var retired: [AVAudioEngine] = []
    private var observer: NSObjectProtocol?
    private(set) var device = AudioDeviceID(kAudioObjectUnknown)
    let activity = Activity()

    init(queue: DispatchQueue) { self.queue = queue }

    /// Builds a fresh engine on `device`, replacing any running one.
    func start(device: AudioDeviceID, _ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        stop()
        self.device = device
        activity.touch(delivered: false)
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Order matters: prepare, set the device, then read the format.
        engine.prepare()
        guard let unit = input.audioUnit else { throw CaptureError.micFailed("no input unit") }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        let format = input.outputFormat(forBus: 0)
        // The node's format can lag a device switch (USB mic at 48 kHz while the node says 44.1 kHz).
        let rate = AudioDevices.nominalSampleRate(device).flatMap { $0 > 0 ? $0 : nil } ?? format.sampleRate
        guard rate > 0, format.channelCount > 0 else { throw CaptureError.micFailed("no usable input format") }
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: format.channelCount)
            ?? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) ?? format
        let resampler = Resampler(.mic, deliver)
        let activity = activity
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            activity.touch()
            resampler.convert(buffer, hostTime: when.isHostTimeValid ? when.hostTime : 0)
        }
        // The engine stops silently when another app grabs the mic or the graph renegotiates; restart it. If it
        // then runs but stays silent, the LiveCapture watchdog rebuilds it.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let engine = self?.engine, !engine.isRunning else { return }
                try? engine.start()
            }
        }
        do { try engine.start() } catch { throw CaptureError.micFailed(error.localizedDescription) }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        retired.append(engine)
        if retired.count > 8 { retired.removeFirst() }
        self.engine = nil
    }
}

enum CaptureError: LocalizedError {
    case noInputDevice, noOutputDevice
    case micFailed(String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)

    /// Core Audio races that a fresh tap usually gets past.
    var isTransient: Bool {
        switch self {
        case .tapFormatUnavailable(kAudioHardwareBadObjectError), .ioProcCreationFailed(kAudioHardwareBadObjectError),
             .startFailed(kAudioHardwareBadObjectError), .tapCreationFailed(kAudioHardwareBadObjectError): true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .noOutputDevice: "No audio output device is currently available."
        case let .micFailed(reason): "The microphone could not start: \(reason)."
        case let .tapCreationFailed(s):
            "System audio capture could not start. Enable System Audio Recording for OpenOats in System Settings > Privacy & Security (OSStatus \(s))."
        case let .aggregateDeviceCreationFailed(s): "Unable to create the Core Audio aggregate device (OSStatus \(s))."
        case let .tapFormatUnavailable(s): "Unable to inspect the system audio tap format (OSStatus \(s))."
        case let .ioProcCreationFailed(s): "Unable to create the system audio IO callback (OSStatus \(s))."
        case let .startFailed(s): "Unable to start system audio capture (OSStatus \(s))."
        }
    }
}
