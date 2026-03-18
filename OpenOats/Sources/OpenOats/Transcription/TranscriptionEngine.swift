import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

/// Simple file logger for diagnostics — writes to /tmp/openoats.log
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/openoats.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    // These properties are read from SwiftUI body during view evaluation.
    // SwiftUI's ViewBodyAccessor doesn't carry MainActor executor context
    // in Swift 6.2, so @MainActor-isolated @Observable properties trigger
    // a failing runtime check in SerialExecutor.isMainExecutor.getter
    // (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE).
    //
    // We use @ObservationIgnored nonisolated(unsafe) backing storage with
    // manual observation tracking to bypass the MainActor check while
    // keeping SwiftUI reactivity. Mutations only happen on MainActor.
    @ObservationIgnored nonisolated(unsafe) private var _isRunning = false
    var isRunning: Bool {
        get { access(keyPath: \.isRunning); return _isRunning }
        set { withMutation(keyPath: \.isRunning) { _isRunning = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assetStatus: String = "Ready"
    var assetStatus: String {
        get { access(keyPath: \.assetStatus); return _assetStatus }
        set { withMutation(keyPath: \.assetStatus) { _assetStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastError: String?
    var lastError: String? {
        get { access(keyPath: \.lastError); return _lastError }
        set { withMutation(keyPath: \.lastError) { _lastError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _needsModelDownload = false
    var needsModelDownload: Bool {
        get { access(keyPath: \.needsModelDownload); return _needsModelDownload }
        set { withMutation(keyPath: \.needsModelDownload) { _needsModelDownload = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadConfirmed = false
    var downloadConfirmed: Bool {
        get { access(keyPath: \.downloadConfirmed); return _downloadConfirmed }
        set { withMutation(keyPath: \.downloadConfirmed) { _downloadConfirmed = newValue } }
    }

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Audio level from mic for the UI meter.
    /// nonisolated is safe here — micCapture.audioLevel is thread-safe (NSLock).
    nonisolated var audioLevel: Float { micCapture.audioLevel }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Shared FluidAudio instances
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
        self.needsModelDownload = !AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2
        )
    }

    func start(locale: Locale, inputDeviceID: AudioDeviceID = 0) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        lastError = nil

        // Block start if models need downloading and user hasn't confirmed
        if needsModelDownload && !downloadConfirmed {
            return
        }

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Load FluidAudio models
        assetStatus = needsModelDownload ? "Downloading ASR model (~600MB)..." : "Loading ASR model..."
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

            needsModelDownload = false
            downloadConfirmed = false
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

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        currentMicDeviceID = targetMicID ?? 0
        diagLog("[ENGINE-3] starting mic capture, targetMicID=\(String(describing: targetMicID))")
        let micStream = micCapture.bufferStream(deviceID: targetMicID)

        // Check for immediate mic capture failure
        if let micError = micCapture.captureError {
            diagLog("[ENGINE-3-FAIL] mic capture error: \(micError)")
            lastError = micError
        }

        // 3. Start system audio capture
        diagLog("[ENGINE-4] starting system audio capture...")
        let sysStreams: SystemAudioCapture.CaptureStreams?
        do {
            sysStreams = try await systemCapture.bufferStream()
            diagLog("[ENGINE-5] system audio capture started OK")
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            sysStreams = nil
        }

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        // Health check: warn if mic produces no audio within 5 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning else { return }
            if !self.micCapture.hasCapturedFrames && self.micCapture.captureError == nil {
                diagLog("[ENGINE-HEALTH] no mic audio after 5s")
                self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
            }
        }

        // 5. Start system audio transcription
        if let sysStream = sysStreams?.systemAudio {
            let sysTranscriber = StreamingTranscriber(
                asrManager: asrManager,
                vadManager: vadManager,
                speaker: .them,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStream)
            }
        }

        assetStatus = "Transcribing (Parakeet-TDT v2)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) async {
        guard isRunning, let asrManager, let vadManager else { return }

        // Only update user selection when explicitly changed (not from OS listener)
        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // Tear down old mic
        micTask?.cancel()
        micCapture.stop()
        await micTask?.value
        micTask = nil

        currentMicDeviceID = targetMicID

        // Start new mic stream
        let micStream = micCapture.bufferStream(deviceID: targetMicID)
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(targetMicID)")
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
                // User has "System Default" selected — follow the OS default
                await self.restartMic(inputDeviceID: 0)
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

    /// Gracefully drain buffered audio before stopping.
    /// Finishes async streams so transcribers flush remaining speech samples,
    /// then awaits task completion before tearing down audio hardware.
    func finalize() async {
        removeDefaultDeviceListener()
        micKeepAliveTask?.cancel()

        // Finish the async streams — causes StreamingTranscriber.run()
        // to exit its for-await loop and hit the final speechSamples flush
        micCapture.finishStream()
        systemCapture.finishStream()

        // Wait for transcriber tasks to complete (includes final flush)
        await micTask?.value
        await sysTask?.value

        // Now safe to tear down audio hardware
        micCapture.stop()
        await systemCapture.stop()

        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
    }

    func stop() {
        removeDefaultDeviceListener()
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        Task { await systemCapture.stop() }
        micCapture.stop()
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
    }
}
