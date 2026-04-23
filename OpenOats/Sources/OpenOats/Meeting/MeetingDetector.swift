import AppKit
import CoreAudio
import Foundation

// MARK: - Audio Signal Source Protocol

/// Abstraction for observing microphone activation status changes.
protocol AudioSignalSource: Sendable {
    /// Emits `true` when any physical input device becomes active, `false` when all go silent.
    var signals: AsyncStream<Bool> { get }
    /// Returns `true` when any monitored device is currently running.
    var isActive: Bool { get }
}

// MARK: - CoreAudio HAL Signal Source

/// Monitors kAudioDevicePropertyDeviceIsRunningSomewhere on all physical input devices.
/// Does NOT capture audio -- only reads activation status.
final class CoreAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "com.openoats.mic-listener")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false

    let signals: AsyncStream<Bool>

    var isActive: Bool {
        listenerQueue.sync {
            deviceIDs.contains { Self.isDeviceRunning($0) }
        }
    }

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        // Install listeners inside listenerQueue.sync to prevent data races
        // between property initialization and the first callback.
        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.physicalInputDeviceIDs()

            for deviceID in self.deviceIDs {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
            }
        }
    }

    deinit {
        for deviceID in deviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        }
        continuation?.finish()
    }

    // MARK: - Listener Callback

    private static let listenerCallback: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.checkAndEmit()
        return kAudioHardwareNoError
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            if anyRunning != self.lastEmittedValue {
                self.lastEmittedValue = anyRunning
                self.continuation?.yield(anyRunning)
            }
        }
    }

    // MARK: - Helpers

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == kAudioHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == kAudioHardwareNoError else { return [] }

        // Filter to devices that have input streams
        return deviceIDs.filter { deviceID in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            return status == kAudioHardwareNoError && inputSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kAudioHardwareNoError && isRunning != 0
    }
}

// MARK: - Detection Trigger

/// Tracks which signal caused the active detection.
enum DetectionTrigger: Sendable {
    case camera
    case micAndApp
}

// MARK: - Meeting Detector Actor

/// Observes camera and microphone activation, correlates with running meeting apps,
/// and determines whether the user is in a meeting using priority-based evaluation.
actor MeetingDetector {
    private let audioSource: any AudioSignalSource
    private let cameraSource: any CameraSignalSource
    private let knownApps: [MeetingAppEntry]
    private let customBundleIDs: [String]
    private let selfBundleID: String
    private let knownBundleIDs: Set<String>

    /// Set to true once detection is confirmed.
    private(set) var isActive = false

    /// The meeting app that was detected, if any.
    private(set) var detectedApp: MeetingApp?

    /// What triggered the current detection.
    private(set) var detectionTrigger: DetectionTrigger?

    /// Emits detection events.
    let events: AsyncStream<MeetingDetectionEvent>
    private let eventContinuation: AsyncStream<MeetingDetectionEvent>.Continuation

    private var micMonitorTask: Task<Void, Never>?
    private var cameraMonitorTask: Task<Void, Never>?
    private var cameraHysteresisTask: Task<Void, Never>?
    private var isCameraActive = false
    private var isMicActive = false
    private var micActiveAt: Date?

    private let debounceSeconds: TimeInterval = 5.0
    private let cameraHysteresisSeconds: TimeInterval = 3.0

    enum MeetingDetectionEvent: Sendable {
        case detected(MeetingApp?)
        case ended
    }

    init(
        audioSource: (any AudioSignalSource)? = nil,
        cameraSource: (any CameraSignalSource)? = nil,
        customBundleIDs: [String] = []
    ) {
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.cameraSource = cameraSource ?? CoreMediaIOSignalSource()
        self.customBundleIDs = customBundleIDs
        self.selfBundleID = Bundle.main.bundleIdentifier ?? "com.openoats.app"

        self.knownApps = Self.defaultMeetingApps
        self.knownBundleIDs = Set(Self.defaultMeetingApps.map(\.bundleID) + customBundleIDs)
            .subtracting([selfBundleID])

        var capturedContinuation: AsyncStream<MeetingDetectionEvent>.Continuation!
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.eventContinuation = capturedContinuation
    }

    deinit {
        micMonitorTask?.cancel()
        cameraMonitorTask?.cancel()
        cameraHysteresisTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        guard micMonitorTask == nil else { return }

        micMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await micIsActive in self.audioSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicSignal(micIsActive)
            }
        }

        cameraMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await cameraIsActive in self.cameraSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleCameraSignal(cameraIsActive)
            }
        }
    }

    func stop() {
        micMonitorTask?.cancel()
        micMonitorTask = nil
        cameraMonitorTask?.cancel()
        cameraMonitorTask = nil
        cameraHysteresisTask?.cancel()
        cameraHysteresisTask = nil
        if isActive {
            isActive = false
            detectedApp = nil
            detectionTrigger = nil
            eventContinuation.yield(.ended)
        }
        micActiveAt = nil
        isCameraActive = false
        isMicActive = false
    }

    // MARK: - Query

    func queryCurrentState() async -> (micActive: Bool, cameraActive: Bool, meetingApp: MeetingApp?) {
        let mic = audioSource.isActive
        let camera = cameraSource.isActive
        let app = await scanForMeetingApp()
        return (mic, camera, app)
    }

    // MARK: - Camera Signal Handling

    private func handleCameraSignal(_ cameraIsActive: Bool) async {
        isCameraActive = cameraIsActive

        if cameraIsActive {
            cameraHysteresisTask?.cancel()
            cameraHysteresisTask = nil

            if !isActive {
                let app = await scanForMeetingApp()
                isActive = true
                detectedApp = app
                detectionTrigger = .camera
                eventContinuation.yield(.detected(app))
            } else {
                // Upgrade trigger to camera if currently mic+app
                detectionTrigger = .camera
            }
        } else {
            cameraHysteresisTask?.cancel()
            cameraHysteresisTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.evaluateCameraOff()
            }
        }
    }

    private func evaluateCameraOff() {
        guard isActive else { return }

        if isMicActive, micActiveAt != nil {
            // Check if a meeting app is still running
            // Use detectedApp as proxy — it was set when detection started
            if detectedApp != nil {
                detectionTrigger = .micAndApp
                return
            }
        }
        // No sustaining signal — end
        isActive = false
        detectedApp = nil
        detectionTrigger = nil
        eventContinuation.yield(.ended)
    }

    // MARK: - Mic Signal Handling

    private func handleMicSignal(_ micIsActive: Bool) async {
        isMicActive = micIsActive

        if micIsActive {
            if micActiveAt == nil {
                micActiveAt = Date()
            }

            let activeSince = micActiveAt!
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            guard micActiveAt == activeSince else { return }

            // If camera already triggered detection, skip
            if isActive { return }

            // Mic alone doesn't trigger — need a meeting app
            let app = await scanForMeetingApp()
            guard app != nil else { return }

            if !isActive {
                isActive = true
                detectedApp = app
                detectionTrigger = .micAndApp
                eventContinuation.yield(.detected(app))
            }
        } else {
            micActiveAt = nil
            isMicActive = false
            if isActive && detectionTrigger == .micAndApp && !isCameraActive {
                isActive = false
                detectedApp = nil
                detectionTrigger = nil
                eventContinuation.yield(.ended)
            }
        }
    }

    // MARK: - Process Scanning

    private func scanForMeetingApp() async -> MeetingApp? {
        let runningApps = await MainActor.run {
            NSWorkspace.shared.runningApplications
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            if knownBundleIDs.contains(bundleID) {
                let name = app.localizedName
                    ?? knownApps.first(where: { $0.bundleID == bundleID })?.displayName
                    ?? bundleID
                return MeetingApp(bundleID: bundleID, name: name)
            }
        }
        return nil
    }

    // MARK: - Default Meeting Apps

    static var bundledMeetingApps: [MeetingAppEntry] {
        defaultMeetingApps
    }

    private static let defaultMeetingApps: [MeetingAppEntry] = [
        MeetingAppEntry(bundleID: "us.zoom.xos", displayName: "Zoom"),
        MeetingAppEntry(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams (classic)"),
        MeetingAppEntry(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        MeetingAppEntry(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex"),
        MeetingAppEntry(bundleID: "app.tuple.app", displayName: "Tuple"),
        MeetingAppEntry(bundleID: "co.around.Around", displayName: "Around"),
        MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
        MeetingAppEntry(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        MeetingAppEntry(bundleID: "com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm", displayName: "Google Meet (PWA)"),
        MeetingAppEntry(bundleID: "ca.illusive.openphone", displayName: "OpenPhone"),
    ]
}
