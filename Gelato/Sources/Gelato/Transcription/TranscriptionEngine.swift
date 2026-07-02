import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

/// Simple file logger for diagnostics — writes to /tmp/opengranola.log
/// Writes happen on a serial utility queue with the throwing FileHandle APIs:
/// the legacy seekToEndOfFile()/write(_:) raise uncatchable NSExceptions on
/// write failure (e.g. disk full), and diagLog is called from audio callbacks.
private let diagLogQueue = DispatchQueue(label: "com.gelato.diaglog", qos: .utility)

func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    diagLogQueue.async {
        let path = "/tmp/opengranola.log"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            do {
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
            } catch {
                // Never crash (or spam) on logging failure.
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore
    private var audioRecorder: SessionAudioRecorder?
    private var currentSessionStart: Date?

    /// Audio level from mic for the UI meter.
    var audioLevel: Float { max(micAudioLevel, systemAudioLevel) }
    var micAudioLevel: Float { micCapture.audioLevel }
    var systemAudioLevel: Float { systemCapture.audioLevel }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Shared FluidAudio instances
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected automatic mic selection (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listens for default output device changes so the system-audio tap follows speaker swaps.
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Debounced mic restart task — cancelled and recreated on each device change notification
    /// so that rapid-fire events (e.g. AirPods disconnect triggers both input + output changes)
    /// collapse into a single restart.
    private var micRestartTask: Task<Void, Never>?
    /// Queued system-capture restart task. Output swaps can fire multiple
    /// notifications back-to-back; only one restart loop may own the tap.
    private var systemRestartTask: Task<Void, Never>?
    /// Remembers that another output-change notification arrived while a
    /// restart was pending or in flight.
    private var pendingSystemRestart = false
    /// In-flight stop, retained so start() can wait for the previous session's
    /// teardown instead of racing it (a stop suspended mid-teardown would
    /// otherwise destroy the NEXT session's capture and recorder).
    private var stopTask: Task<Void, Never>?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        sessionStart: Date = .now,
        audioRecorder: SessionAudioRecorder? = nil
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        // Never start on top of a stop that is still tearing down.
        if let stopTask {
            diagLog("[ENGINE-0] waiting for previous stop() to finish")
            await stopTask.value
        }
        guard !isRunning else { return }
        lastError = nil
        self.audioRecorder = audioRecorder
        self.currentSessionStart = sessionStart

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Load FluidAudio models
        assetStatus = "Loading ASR model (~600MB first run)..."
        diagLog("[ENGINE-1] loading FluidAudio ASR models...")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            assetStatus = "Initializing ASR..."
            let asr = AsrManager(config: .default)
            try await asr.initialize(models: models)
            self.asrManager = asr

            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] FluidAudio models loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let asrManager, let vadManager else { return }

        let audioRecorder = self.audioRecorder

        // 2. Start system audio capture first so we fail fast if "Them" audio
        // can't be captured for this session.
        diagLog("[ENGINE-3] starting system audio capture")
        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            sysStreams = try await systemCapture.bufferStream(
                onSystemBuffer: { capturedBuffer in
                    audioRecorder?.appendSystemBuffer(capturedBuffer)
                }
            )
        } catch {
            let msg = "System audio capture failed: \(error.localizedDescription)"
            diagLog("[ENGINE-3-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        // 3. Start mic capture + transcription
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.automaticInputDeviceID() ?? 0
        currentMicDeviceID = targetMicID
        if inputDeviceID == 0 {
            diagLog("[ENGINE-4] automatic mic resolved to \(targetMicID) (\(MicCapture.automaticInputDeviceName() ?? "unknown"))")
        } else {
            diagLog("[ENGINE-4] starting mic capture, targetMicID=\(targetMicID)")
        }
        if !startMicPipeline(targetMicID: targetMicID),
           inputDeviceID > 0,
           let fallbackID = MicCapture.automaticInputDeviceID(),
           fallbackID != targetMicID {
            // The requested device failed (unplugged, dead battery) — fall back to
            // the automatic pick so the session still records mic audio.
            diagLog("[ENGINE-4] requested mic failed, falling back to automatic device \(fallbackID)")
            micCapture.stop()
            if startMicPipeline(targetMicID: fallbackID) {
                currentMicDeviceID = fallbackID
                lastError = nil
            }
        }

        // 5. Start system audio transcription
        let store = transcriptStore
        let sysTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .them,
            sessionStart: sessionStart,
            segmentationConfig: Self.systemVadSegmentationConfig,
            inputGain: Self.systemInputGain,
            onPartial: { text in
                Task { @MainActor in store.volatileThemText = text }
            },
            onFinal: { text, timestamp in
                Task { @MainActor in
                    store.volatileThemText = ""
                    store.append(Utterance(text: text, speaker: .them, timestamp: timestamp))
                }
            }
        )
        sysTask = Task.detached {
            await sysTranscriber.run(stream: sysStreams.systemAudio)
        }

        assetStatus = "Transcribing (Parakeet-TDT v2)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
        installDefaultOutputDeviceListener()
    }

    /// Schedule a debounced mic restart. Multiple calls within 300ms collapse into one,
    /// coalescing the input + output device change notifications that fire simultaneously
    /// when AirPods connect/disconnect.
    private func scheduleMicRestart() {
        micRestartTask?.cancel()
        micRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            let requestedMicID = self.userSelectedDeviceID
            self.restartMic(inputDeviceID: requestedMicID, force: true)
        }
    }

    /// Queue a system restart. This follows OpenOats' stream-first shutdown:
    /// finish the old stream, wait for its transcriber to exit, then tear down
    /// the CoreAudio tap before creating a new one.
    private func restartSystemCapture() {
        guard isRunning else { return }
        pendingSystemRestart = true
        guard systemRestartTask == nil else {
            diagLog("[ENGINE-SYS-SWAP] restart already running; queued another pass")
            return
        }

        systemRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.systemRestartTask = nil }

            while self.isRunning, self.pendingSystemRestart, !Task.isCancelled {
                self.pendingSystemRestart = false
                await self.performSystemCaptureRestart()
            }
        }
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = automatic selection, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID, force: Bool = false) {
        guard isRunning, asrManager != nil, vadManager != nil else { return }

        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.automaticInputDeviceID() ?? 0
        guard force || targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // Tear down old mic
        micCapture.finishStream()
        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = targetMicID

        // Start new mic stream — makeFreshEngine() inside bufferStream handles
        // format negotiation automatically, no stabilization delay needed.
        if !startMicPipeline(targetMicID: targetMicID),
           let fallbackID = MicCapture.automaticInputDeviceID(),
           fallbackID != targetMicID {
            // The requested device failed mid-session (unplugged, dead battery).
            // Fall back to the automatic pick instead of silently recording no mic.
            diagLog("[ENGINE-MIC-SWAP] device \(targetMicID) failed, falling back to \(fallbackID)")
            micCapture.stop()
            if startMicPipeline(targetMicID: fallbackID) {
                currentMicDeviceID = fallbackID
                lastError = nil
            }
        }

        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(currentMicDeviceID)")
    }

    /// Start the mic capture stream and its transcriber for the given device.
    /// Returns false — and sets `lastError` — when the capture engine failed to start.
    @discardableResult
    private func startMicPipeline(targetMicID: AudioDeviceID) -> Bool {
        guard let asrManager, let vadManager else { return false }

        let audioRecorder = self.audioRecorder
        let micStream = micCapture.bufferStream(
            deviceID: targetMicID > 0 ? targetMicID : nil,
            onBuffer: { capturedBuffer in
                audioRecorder?.appendMicBuffer(capturedBuffer)
            }
        )

        if let error = micCapture.captureError {
            diagLog("[ENGINE-MIC-START-FAIL] \(error)")
            lastError = "Microphone capture failed: \(error)"
            return false
        }

        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            sessionStart: currentSessionStart ?? .now,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, timestamp in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you, timestamp: timestamp))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }
        return true
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                diagLog("[ENGINE-DEVICE-CHANGE] default input device changed, scheduling mic restart")
                self.scheduleMicRestart()
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                diagLog("[ENGINE-DEVICE-CHANGE] default output device changed, scheduling system + mic restart")
                self.restartSystemCapture()
                self.scheduleMicRestart()
            }
        }
        defaultOutputDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultOutputDeviceListenerBlock = nil
    }

    private func performSystemCaptureRestart() async {
        guard isRunning, let asrManager, let vadManager else { return }

        diagLog("[ENGINE-SYS-SWAP] restarting system capture for output device change")
        // systemCapture.stop() flushes the buffered tail into the recorder and the
        // stream FIRST, then finishes the stream — which lets the transcriber task
        // exit on its own. (Finishing the stream before stopping would drop the
        // tail audio around every device switch.)
        await systemCapture.stop()
        await sysTask?.value
        sysTask = nil
        guard isRunning, !Task.isCancelled else { return }

        let audioRecorder = self.audioRecorder

        // Reset the audio recorder's system converter so it rebuilds for the
        // new device's format instead of reusing stale conversion state.
        audioRecorder?.resetSystemFormat()

        do {
            let sysStreams = try await systemCapture.bufferStream(
                onSystemBuffer: { capturedBuffer in
                    audioRecorder?.appendSystemBuffer(capturedBuffer)
                }
            )
            // stop() may have run while we were suspended in bufferStream —
            // tear the fresh capture down instead of leaving a zombie tap alive.
            guard isRunning, !Task.isCancelled else {
                diagLog("[ENGINE-SYS-SWAP] engine stopped during restart, tearing down fresh capture")
                await systemCapture.stop()
                return
            }
            let store = transcriptStore
            let sysTranscriber = StreamingTranscriber(
                asrManager: asrManager,
                vadManager: vadManager,
                speaker: .them,
                sessionStart: currentSessionStart ?? .now,
                segmentationConfig: Self.systemVadSegmentationConfig,
                inputGain: Self.systemInputGain,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text, timestamp in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them, timestamp: timestamp))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStreams.systemAudio)
            }
            diagLog("[ENGINE-SYS-SWAP] system capture restarted")
        } catch {
            let msg = "System audio capture restart failed: \(error.localizedDescription)"
            diagLog("[ENGINE-SYS-SWAP-FAIL] \(msg)")
            lastError = msg
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func stop() async {
        // Serialize stops: concurrent callers all await the same teardown, and
        // start() awaits `stopTask` so a new session can never race a stop that
        // is suspended mid-teardown.
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        diagLog("[ENGINE-STOP] begin")
        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        micRestartTask = nil
        let restartTask = systemRestartTask
        restartTask?.cancel()
        pendingSystemRestart = false
        let micTask = self.micTask
        self.micKeepAliveTask?.cancel()
        self.micTask = nil
        self.micKeepAliveTask = nil
        isRunning = false
        assetStatus = "Ready"

        // Let any in-flight system-capture restart wind down (its post-await
        // guards see isRunning == false and tear down whatever it created)
        // before we tear down the capture ourselves.
        await restartTask?.value
        systemRestartTask = nil

        micCapture.finishStream()
        micTask?.cancel()
        await micTask?.value
        micCapture.stop()

        let systemCapture = self.systemCapture
        let recorder = audioRecorder
        audioRecorder = nil
        currentSessionStart = nil
        currentMicDeviceID = 0

        // systemCapture.stop() flushes the tail into the recorder before finishing
        // the stream, which also ends the system transcriber's loop.
        await Task.detached(priority: .userInitiated) {
            await systemCapture.stop()
        }.value
        let sysTask = self.sysTask
        self.sysTask = nil
        sysTask?.cancel()
        await sysTask?.value

        await Task.detached(priority: .userInitiated) {
            _ = recorder?.finish()
        }.value
        diagLog("[ENGINE-STOP] recorder finished")
        diagLog("[ENGINE-STOP] end")
    }

    private static let systemInputGain: Float = 2.5

    private static let systemVadSegmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.12,
        minSilenceDuration: 0.45,
        maxSpeechDuration: 14.0,
        speechPadding: 0.1,
        silenceThresholdForSplit: 0.25,
        negativeThreshold: 0.23,
        negativeThresholdOffset: 0.22,
        minSilenceAtMaxSpeech: 0.098,
        useMaxPossibleSilenceAtMaxSpeech: true
    )
}
