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
    /// Bundle IDs of processes with an active input stream, or nil when unknown.
    var micHolderBundleIDs: [String]? { get }
}

extension AudioSignalSource {
    var micHolderBundleIDs: [String]? { nil }
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

    /// Reads `kAudioProcessPropertyIsRunningInput` per Core Audio process object (macOS 14+).
    var micHolderBundleIDs: [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == kAudioHardwareNoError else { return nil }
        var processIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processIDs) == kAudioHardwareNoError else { return nil }

        var holders: [String] = []
        for processID in processIDs {
            address.mSelector = kAudioProcessPropertyIsRunningInput
            var running: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &running) == kAudioHardwareNoError,
                  running != 0 else { continue }

            address.mSelector = kAudioProcessPropertyBundleID
            var bundleID: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &bundleID)
            // An unidentifiable holder must not look like a dictation app.
            holders.append(status == kAudioHardwareNoError ? (bundleID?.takeRetainedValue() as String?) ?? "" : "")
        }
        return holders
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
    /// Running apps as (bundle ID, display name). NSWorkspace unless injected.
    private let runningApps: @Sendable () async -> [(bundleID: String, name: String?)]
    /// Resolved detection set, case-folded. Built by `resolveKnownBundleIDs`.
    private let knownBundleIDs: Set<String>

    /// Set to true once detection is confirmed.
    private(set) var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                startHolderMonitor()
            } else {
                stopHolderMonitor()
            }
        }
    }

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

    /// How long every meeting app must have released the mic before the meeting
    /// counts as over. Covers a brief mute/unmute or a reconnect.
    static let defaultMeetingEndGraceSeconds: TimeInterval = 30.0
    private let meetingEndGraceSeconds: TimeInterval
    private let holderPollSeconds: TimeInterval

    private var holderMonitorTask: Task<Void, Never>?
    /// True once a meeting app has been seen holding the mic during this detection.
    /// Without it, a meeting held in an app we cannot attribute (a browser tab)
    /// would look "released" from the first poll.
    private var meetingHolderSeen = false
    /// When the meeting-holder set last became empty; nil while one is present.
    private var meetingHoldersEmptySince: Date?

    enum MeetingDetectionEvent: Sendable {
        case detected(MeetingApp?)
        case ended
    }

    init(
        audioSource: (any AudioSignalSource)? = nil,
        cameraSource: (any CameraSignalSource)? = nil,
        customBundleIDs: [String] = [],
        meetingEndGraceSeconds: TimeInterval = MeetingDetector.defaultMeetingEndGraceSeconds,
        holderPollSeconds: TimeInterval = 2.0,
        runningApps: (@Sendable () async -> [(bundleID: String, name: String?)])? = nil
    ) {
        self.runningApps = runningApps ?? {
            await MainActor.run {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier.map { ($0, app.localizedName) }
                }
            }
        }
        self.meetingEndGraceSeconds = meetingEndGraceSeconds
        self.holderPollSeconds = holderPollSeconds
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.cameraSource = cameraSource ?? CoreMediaIOSignalSource()
        self.customBundleIDs = customBundleIDs
        self.selfBundleID = Bundle.main.bundleIdentifier ?? "com.openoats.app"

        self.knownApps = Self.defaultMeetingApps
        self.knownBundleIDs = Self.resolveKnownBundleIDs(
            custom: customBundleIDs,
            selfID: selfBundleID
        )

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
        holderMonitorTask?.cancel()
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

            // A dictation app holding the mic is not a call, even with a meeting app open.
            if Self.isDictationOnly(audioSource.micHolderBundleIDs) { return }

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
        var candidates: [MeetingApp] = []
        for app in await runningApps() {
            let bundleID = app.bundleID
            let folded = bundleID.lowercased()
            if knownBundleIDs.contains(folded) {
                let name = app.name
                    ?? knownApps.first(where: { $0.bundleID.lowercased() == folded })?.displayName
                    ?? bundleID
                candidates.append(MeetingApp(bundleID: bundleID, name: name))
            }
        }
        return Self.preferredMeetingApp(
            candidates: candidates,
            holders: Self.meetingMicHolders(audioSource.micHolderBundleIDs, knownBundleIDs: knownBundleIDs)
        )
    }

    /// Of the running meeting apps, the one actually holding the mic wins; with no
    /// holder information the first running app is used, as before. Otherwise a
    /// huddle gets attributed to whichever known app happens to be running first.
    static func preferredMeetingApp(candidates: [MeetingApp], holders: [String]?) -> MeetingApp? {
        if let holders, let holding = candidates.first(where: { candidate in
            holders.contains { holderMatches($0, bundleID: candidate.bundleID) }
        }) {
            return holding
        }
        return candidates.first
    }

    // MARK: - Meeting Mic Holders

    /// Mic holders that are meeting apps (allowlist plus custom apps, never OpenOats
    /// itself, which `knownBundleIDs` already excludes). Nil when holder information
    /// is unavailable, so callers can fall back to the device-level signal.
    static func meetingMicHolders(_ holders: [String]?, knownBundleIDs: Set<String>) -> [String]? {
        guard let holders else { return nil }
        return holders.filter { holder in
            knownBundleIDs.contains { holderMatches(holder, bundleID: $0) }
        }
    }

    /// Exact match, or a helper process of the app ("<id>.helper"), folded.
    private static func holderMatches(_ holder: String, bundleID: String) -> Bool {
        let holder = holder.lowercased()
        let id = bundleID.lowercased()
        return holder == id || holder.hasPrefix(id + ".")
    }

    // MARK: - Per-Process Meeting End

    /// OpenOats' own capture keeps the input device "running somewhere", so the
    /// device-level signal never drops while it records. Watching which processes
    /// hold the mic instead notices a meeting app letting go.
    private func startHolderMonitor() {
        holderMonitorTask?.cancel()
        meetingHolderSeen = false
        meetingHoldersEmptySince = nil
        let interval = holderPollSeconds
        holderMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateMeetingHolders()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopHolderMonitor() {
        holderMonitorTask?.cancel()
        holderMonitorTask = nil
        meetingHolderSeen = false
        meetingHoldersEmptySince = nil
    }

    private func evaluateMeetingHolders() {
        guard isActive, detectionTrigger == .micAndApp, !isCameraActive else {
            meetingHoldersEmptySince = nil
            return
        }
        // Holder info unavailable: the any-device path in handleMicSignal is the fallback.
        guard let holders = Self.meetingMicHolders(audioSource.micHolderBundleIDs, knownBundleIDs: knownBundleIDs) else {
            return
        }

        if !holders.isEmpty {
            meetingHolderSeen = true
            meetingHoldersEmptySince = nil
            return
        }
        guard meetingHolderSeen else { return }

        let now = Date()
        let since = meetingHoldersEmptySince ?? now
        meetingHoldersEmptySince = since
        guard now.timeIntervalSince(since) >= meetingEndGraceSeconds else { return }

        isActive = false
        detectedApp = nil
        detectionTrigger = nil
        eventContinuation.yield(.ended)
    }

    // MARK: - Dictation Apps

    /// True only when every process holding the mic is a known dictation app.
    /// Unknown or empty holder lists fall back to normal detection.
    static func isDictationOnly(_ holders: [String]?) -> Bool {
        guard let holders, !holders.isEmpty else { return false }
        return holders.allSatisfy { holder in
            let folded = holder.lowercased()
            // Prefix match so helper processes (e.g. "<id>.helper") count too.
            return dictationBundleIDPrefixes.contains { folded.hasPrefix($0) }
        }
    }

    private static let dictationBundleIDPrefixes: [String] = [
        "com.superduper.superwhisper",
        "com.electron.wispr-flow",
        "com.goodsnooze.macwhisper",
        "com.prakashjoshipax.voiceink",
        "inc.synth.onit",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.google.geminimacos",
        "com.google.antigravity",
    ]

    // MARK: - Default Meeting Apps

    static var bundledMeetingApps: [MeetingAppEntry] {
        defaultMeetingApps
    }

    /// Merge the bundled defaults with the user's custom bundle identifiers and
    /// drop the app's own identifier. Bundle identifiers are compared without
    /// regard to case — "us.Zoom.xos" is the same app as "us.zoom.xos" — so the
    /// result is case-folded, and every lookup folds the incoming identifier too.
    /// Pure, so the merge can be tested without standing up a detector.
    static func resolveKnownBundleIDs(
        defaults: [MeetingAppEntry] = bundledMeetingApps,
        custom: [String],
        selfID: String
    ) -> Set<String> {
        let merged = defaults.map(\.bundleID) + custom
        return Set(merged.map { $0.lowercased() }).subtracting([selfID.lowercased()])
    }

    /// True when the identifier is already one of the bundled defaults, so the
    /// UI can refuse an addition that would look removable but never be removed
    /// from detection. Case- and whitespace-insensitive.
    static func isBundledMeetingApp(_ bundleID: String) -> Bool {
        let folded = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bundledMeetingApps.contains { $0.bundleID.lowercased() == folded }
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
        // The shipping Slack desktop app's actual bundle identifier.
        MeetingAppEntry(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
        MeetingAppEntry(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        MeetingAppEntry(bundleID: "com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm", displayName: "Google Meet (PWA)"),
        MeetingAppEntry(bundleID: "ca.illusive.openphone", displayName: "OpenPhone"),
    ]
}
