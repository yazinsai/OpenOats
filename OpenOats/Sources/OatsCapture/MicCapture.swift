@preconcurrency import AVFoundation
import CoreAudio
import OatsCore
import OatsObjC

/// The Mic track: an AVAudioEngine input tap on one device. Used on the LiveCapture queue only.
final class MicCapture: @unchecked Sendable {
    /// What a tap was made for: the input unit's device and the hardware format.
    struct Binding: Equatable {
        var device: AudioDeviceID
        var rate: Double
        var channels: AVAudioChannelCount
    }

    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    private var bound: Binding?
    /// AVAudioEngine teardown races AVAudioIOUnit callbacks during route changes (AirPods); keep recently
    /// stopped engines alive so AVFAudio's internal queues can drain.
    private var retired: [AVAudioEngine] = []
    private var observer: NSObjectProtocol?
    private(set) var device = AudioDeviceID(kAudioObjectUnknown)
    let activity = Activity()

    init(queue: DispatchQueue) { self.queue = queue }

    /// True when the input unit moved to another device, or the hardware has a usable format other than the tap's. An
    /// unknown device or unusable format (mid switch) is left to the restart and the watchdog.
    static func rebound(_ tap: Binding, now: Binding) -> Bool {
        (now.device != kAudioObjectUnknown && now.device != tap.device)
            || (now.rate > 0 && now.channels > 0 && (now.rate != tap.rate || now.channels != tap.channels))
    }

    /// Whether the running engine is no longer bound the way its tap was made. Cheap; reads the unit and node.
    var isRebound: Bool {
        guard let engine, let bound, let unit = engine.inputNode.audioUnit else { return false }
        let hardware = try? Self.guarded { engine.inputNode.inputFormat(forBus: 0) }
        let now = Binding(device: Self.device(of: unit) ?? AudioDeviceID(kAudioObjectUnknown),
                          rate: hardware?.sampleRate ?? 0, channels: hardware?.channelCount ?? 0)
        return Self.rebound(bound, now: now)
    }

    private static func device(of unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

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
        // Read back, so a fresh engine is never rebound by construction.
        bound = Binding(device: Self.device(of: unit) ?? device, rate: rate, channels: channels)
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
        bound = nil
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
