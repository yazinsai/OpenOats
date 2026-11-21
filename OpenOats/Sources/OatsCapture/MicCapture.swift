@preconcurrency import AVFoundation
import CoreAudio
import OatsCore
import OatsObjC

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

    /// Builds a fresh engine on `device`, replacing any running one. On failure the engine is retired again.
    func start(device: AudioDeviceID, _ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        stop()
        self.device = device
        activity.touch(delivered: false)
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            try build(engine, device: device, deliver)
        } catch {
            stop()
            throw error
        }
    }

    private func build(_ engine: AVAudioEngine, device: AudioDeviceID, _ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        let input = engine.inputNode
        // Order matters: prepare, set the device, then read the format.
        try Self.guarded { engine.prepare() }
        guard let unit = input.audioUnit else { throw CaptureError.micFailed("no input unit") }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        // The tap must run at the engine's input hardware rate, or AVFAudio raises. The node's output format can lag a
        // device switch (#70: USB mic at 48 kHz, node at 44.1 kHz), and the device's nominal rate can disagree with the
        // hardware mid Bluetooth A2DP ↔ HFP switch, so both are only fallbacks. The Resampler takes any rate.
        let hardware = input.inputFormat(forBus: 0), output = input.outputFormat(forBus: 0)
        let usable = hardware.sampleRate > 0 && hardware.channelCount > 0
        let rate = usable ? hardware.sampleRate
            : AudioDevices.nominalSampleRate(device).flatMap { $0 > 0 ? $0 : nil } ?? output.sampleRate
        let channels = usable ? hardware.channelCount : output.channelCount
        guard rate > 0, channels > 0, let tapFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)
        else { throw CaptureError.micFailed("no usable input format") }
        let resampler = Resampler(.mic, deliver)
        let activity = activity
        try Self.guarded {
            input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
                activity.touch()
                resampler.convert(buffer, hostTime: when.isHostTimeValid ? when.hostTime : 0)
            }
        }
        // The engine stops silently when another app grabs the mic or the graph renegotiates; restart it. If that
        // fails, or it runs but stays silent, the mic stops delivering and the LiveCapture watchdog rebuilds it.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let engine = self?.engine, !engine.isRunning else { return }
                try? Self.guarded { try engine.start() }
            }
        }
        try Self.guarded { try engine.start() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        _ = OatsCatchException { engine.inputNode.removeTap(onBus: 0) }
        _ = OatsCatchException { engine.stop() }
        _ = OatsCatchException { engine.reset() }
        retired.append(engine)
        if retired.count > 8 { retired.removeFirst() }
        self.engine = nil
    }

    /// Runs an AVFAudio call, turning a thrown error or a raised NSException (which Swift can't catch) into `micFailed`.
    static func guarded<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, any Error>?
        if let exception = OatsCatchException({ result = Result(catching: body) }) {
            throw CaptureError.micFailed(exception.localizedDescription)
        }
        guard let result else { throw CaptureError.micFailed("no result") }
        do { return try result.get() } catch { throw CaptureError.micFailed(error.localizedDescription) }
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
