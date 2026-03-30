import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

enum TranscriptionEngineError: LocalizedError {
    case transcriberNotInitialized

    var errorDescription: String? {
        switch self {
        case .transcriberNotInitialized:
            "Transcription engine is not initialized. Please check your audio settings."
        }
    }
}

/// Enriched download progress info computed from fraction changes over time.
struct DownloadProgressDetail: Sendable {
    let fraction: Double
    /// Formatted string like "142 MB / 800 MB"
    let sizeText: String?
    /// Formatted string like "3.5 MB/s"
    let speedText: String?
    /// Formatted string like "2m 15s remaining"
    let etaText: String?
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    enum Mode {
        case live
        case scripted([Utterance])
    }

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

    @ObservationIgnored nonisolated(unsafe) private var _downloadProgress: Double?
    /// Fraction complete (0…1) during model download, nil when not downloading.
    var downloadProgress: Double? {
        get { access(keyPath: \.downloadProgress); return _downloadProgress }
        set { withMutation(keyPath: \.downloadProgress) { _downloadProgress = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadDetail: DownloadProgressDetail?
    var downloadDetail: DownloadProgressDetail? {
        get { access(keyPath: \.downloadDetail); return _downloadDetail }
        set { withMutation(keyPath: \.downloadDetail) { _downloadDetail = newValue } }
    }

    // Progress tracking state (not observed)
    @ObservationIgnored private var downloadStartTime: Date?
    @ObservationIgnored private var downloadTotalBytes: Int64?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore
    private let settings: AppSettings
    private let mode: Mode

    /// Combined audio level (mic + system) for the UI meter.
    /// nonisolated is safe here — both audioLevel properties are thread-safe (NSLock).
    nonisolated var audioLevel: Float {
        switch mode {
        case .live:
            max(micCapture.audioLevel, systemCapture.audioLevel)
        case .scripted:
            _isRunning ? 0.35 : 0
        }
    }

    /// Mute/unmute the microphone. When muted, mic audio is not transcribed
    /// and the audio level reads as 0. System audio continues normally.
    nonisolated var isMicMuted: Bool {
        get { micCapture.isMuted }
        set { micCapture.isMuted = newValue }
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Separate backend instances for mic and system audio.
    /// Parakeet keeps mutable decoder state per manager, so mic and system audio
    /// need separate instances even when they share the same loaded model files.
    /// For Qwen3 (actor-based, thread-safe), both point to the same backend instance.
    private var micBackend: (any TranscriptionBackend)?
    private var systemBackend: (any TranscriptionBackend)?
    private var vadManager: VadManager?

    /// Audio recorder for tapping streams (set by ContentView when recording is enabled).
    var audioRecorder: AudioRecorder?

    /// Speaker diarization manager for system audio (nil when diarization is disabled).
    private var diarizationManager: DiarizationManager?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listens for default output device changes at the OS level.
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var micRestartTask: Task<Void, Never>?
    private var sysRestartTask: Task<Void, Never>?
    private var pendingMicDeviceID: AudioDeviceID?
    private var pendingSystemAudioRestart = false

    init(transcriptStore: TranscriptStore, settings: AppSettings, mode: Mode = .live) {
        self.transcriptStore = transcriptStore
        self.settings = settings
        self.mode = mode
        switch mode {
        case .live:
            self.needsModelDownload = Self.modelNeedsDownload(settings.transcriptionModel)
        case .scripted:
            self.needsModelDownload = false
        }
    }

    func refreshModelAvailability() {
        switch mode {
        case .live:
            needsModelDownload = Self.modelNeedsDownload(settings.transcriptionModel)
        case .scripted:
            needsModelDownload = false
        }
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        transcriptionModel: TranscriptionModel
    ) async {
        Log.transcription.info("start() called, isRunning=\(self.isRunning, privacy: .public)")
        guard !isRunning else { return }
        lastError = nil
        refreshModelAvailability()

        if case .scripted(let scriptedUtterances) = mode {
            downloadConfirmed = false
            assetStatus = "Transcribing (UI Test)"
            isRunning = true
            for utterance in scriptedUtterances {
                transcriptStore.append(utterance)
            }
            return
        }

        if let localeMismatchMessage = localeMismatchMessage(
            for: locale,
            transcriptionModel: transcriptionModel
        ) {
            lastError = localeMismatchMessage
            assetStatus = "Ready"
            return
        }

        // Block start if models need downloading and user hasn't confirmed
        if needsModelDownload && !downloadConfirmed {
            return
        }

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Load transcription models via backend protocol
        let isDownloading = needsModelDownload
        assetStatus = isDownloading
            ? "Downloading \(transcriptionModel.displayName)..."
            : "Loading \(transcriptionModel.displayName)..."
        if isDownloading {
            downloadProgress = 0
            downloadStartTime = Date()
            downloadTotalBytes = transcriptionModel.estimatedDownloadBytes
            downloadDetail = DownloadProgressDetail(fraction: 0, sizeText: nil, speedText: nil, etaText: nil)
        }
        Log.transcription.info("Loading transcription model \(transcriptionModel.rawValue, privacy: .public)")
        do {
            let vocab = settings.transcriptionCustomVocabulary
            let mic = transcriptionModel.makeBackend(customVocabulary: vocab)
            try await mic.prepare(
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        self?.assetStatus = status
                    }
                },
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.downloadProgress = fraction
                        self?.updateDownloadDetail(fraction: fraction)
                    }
                }
            )
            self.micBackend = mic

            // Parakeet needs a separate backend for system audio (mutable decoder state).
            // Qwen3 is actor-based and thread-safe, so reuse the same instance.
            if transcriptionModel == .qwen3ASR06B {
                self.systemBackend = mic
            } else {
                let sys = transcriptionModel.makeBackend(customVocabulary: vocab)
                try await sys.prepare { _ in }
                self.systemBackend = sys
            }

            assetStatus = "Loading VAD model..."
            Log.transcription.info("Loading VAD model")
            let vad = try await VadManager()
            self.vadManager = vad

            // Optionally load speaker diarization model
            if settings.enableDiarization {
                assetStatus = "Loading diarization model..."
                Log.transcription.info("Loading LS-EEND diarization model")
                let dm = DiarizationManager()
                let variant = LSEENDVariant(rawValue: settings.diarizationVariant.rawValue) ?? .dihard3
                try await dm.load(variant: variant)
                self.diarizationManager = dm
                Log.transcription.info("Diarization model loaded")
            } else {
                self.diarizationManager = nil
            }

            needsModelDownload = false
            downloadConfirmed = false
            downloadProgress = nil
            downloadDetail = nil
            downloadStartTime = nil
            downloadTotalBytes = nil
            assetStatus = "Models ready"
            Log.transcription.info("Transcription model loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            Log.transcription.error("Failed to load models: \(msg, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            downloadProgress = nil
            downloadDetail = nil
            downloadStartTime = nil
            downloadTotalBytes = nil
            // Clear corrupt cache so the next attempt triggers a fresh download
            settings.transcriptionModel.makeBackend().clearModelCache()
            Log.transcription.info("Cleared model cache for \(self.settings.transcriptionModel.rawValue, privacy: .public)")
            needsModelDownload = true
            downloadConfirmed = false
            return
        }

        guard let vadManager else { return }

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        guard let targetMicID = resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = unavailableMicMessage(for: inputDeviceID)
            Log.transcription.error("Mic unavailable: \(msg, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }
        currentMicDeviceID = targetMicID
        // AEC (voice processing) conflicts with system audio capture on macOS —
        // both cause CoreAudio aggregate-device reconfiguration that can stall the
        // mic stream. Since system audio capture is always active during recording,
        // AEC must be disabled to prevent capture failures.
        let useAEC = false
        if settings.enableEchoCancellation {
            Log.transcription.info("AEC disabled - conflicts with system audio capture")
        }

        Log.transcription.info("Starting mic capture, targetMicID=\(targetMicID, privacy: .public), aec=\(useAEC, privacy: .public)")
        startMicStream(
            locale: locale,
            vadManager: vadManager,
            deviceID: targetMicID,
            echoCancellation: useAEC
        )

        // Check for immediate mic capture failure
        if let micError = micCapture.captureError {
            Log.transcription.error("Mic capture error: \(micError, privacy: .public)")
            lastError = micError
        }

        // Health check: if mic produces no audio within 5 seconds, retry once
        // without AEC before surfacing the error.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning else { return }
            if !self.micCapture.hasCapturedFrames && self.micCapture.captureError == nil {
                if useAEC {
                    Log.transcription.error("No mic audio after 5s with AEC, retrying without")
                    self.micCapture.finishStream()
                    await self.micTask?.value
                    self.micTask = nil
                    self.micCapture.stop()
                    self.startMicStream(
                        locale: locale,
                        vadManager: vadManager,
                        deviceID: targetMicID,
                        echoCancellation: false
                    )
                } else {
                    Log.transcription.error("No mic audio after 5s")
                    self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
                }
            }
        }

        // 3. Start system audio capture
        await startSystemAudioStream(locale: locale, vadManager: vadManager)

        assetStatus = "Transcribing (\(micBackend?.displayName ?? transcriptionModel.displayName))"
        Log.transcription.info("All transcription tasks started")

        // Install CoreAudio listeners for live device routing changes
        installDefaultDeviceListener()
        installDefaultOutputDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) {
        if case .scripted = mode { return }
        guard isRunning else { return }
        pendingMicDeviceID = inputDeviceID

        if micRestartTask != nil {
            Log.transcription.info("Queued mic restart for device \(inputDeviceID, privacy: .public)")
            return
        }

        micRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.micRestartTask = nil }

            while self.isRunning, let requestedDeviceID = self.pendingMicDeviceID {
                self.pendingMicDeviceID = nil
                await self.performMicRestart(inputDeviceID: requestedDeviceID)
            }
        }
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
                self.restartMic(inputDeviceID: 0)
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
                self.restartSystemAudio()
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

    func finalize() async {
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            return
        }

        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false
        micKeepAliveTask?.cancel()

        micCapture.finishStream()
        systemCapture.finishStream()

        await micTask?.value
        await sysTask?.value

        micCapture.stop()
        await systemCapture.stop()

        micTask = nil
        sysTask = nil
        pendingMicDeviceID = nil
        micKeepAliveTask = nil
        currentMicDeviceID = 0
        // Finalize and release diarization manager
        if let dm = diarizationManager {
            await dm.finalize()
        }
        diarizationManager = nil

        micBackend = nil
        systemBackend = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        isRunning = false
        assetStatus = "Ready"
    }

    func stop() {
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            return
        }

        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        Task { await systemCapture.stop() }
        micCapture.stop()
        currentMicDeviceID = 0
        micBackend = nil
        systemBackend = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        isRunning = false
        assetStatus = "Ready"
    }

    private func performMicRestart(inputDeviceID: AudioDeviceID) async {
        guard isRunning, let vadManager else { return }

        userSelectedDeviceID = inputDeviceID

        guard let targetMicID = resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = unavailableMicMessage(for: inputDeviceID)
            Log.transcription.error("Mic swap failed: \(msg, privacy: .public)")
            lastError = msg
            return
        }

        guard targetMicID != currentMicDeviceID else {
            Log.transcription.debug("Mic swap skipped, same device \(targetMicID, privacy: .public)")
            return
        }

        Log.transcription.info("Switching mic from \(self.currentMicDeviceID, privacy: .public) to \(targetMicID, privacy: .public)")

        micCapture.finishStream()
        await micTask?.value

        if Task.isCancelled || !isRunning {
            return
        }

        micTask = nil
        micCapture.stop()
        startMicStream(
            locale: settings.locale,
            vadManager: vadManager,
            deviceID: targetMicID
        )
        currentMicDeviceID = targetMicID
        lastError = nil

        Log.transcription.info("Mic restarted on device \(targetMicID, privacy: .public)")
    }

    private func restartSystemAudio() {
        guard isRunning else { return }
        pendingSystemAudioRestart = true

        if sysRestartTask != nil {
            Log.transcription.info("Queued system audio restart")
            return
        }

        sysRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sysRestartTask = nil }

            while self.isRunning, self.pendingSystemAudioRestart {
                self.pendingSystemAudioRestart = false
                await self.performSystemAudioRestart()
            }
        }
    }

    private func performSystemAudioRestart() async {
        guard isRunning, let vadManager else { return }

        Log.transcription.info("Restarting system audio stream")

        systemCapture.finishStream()
        await sysTask?.value

        if Task.isCancelled || !isRunning {
            return
        }

        sysTask = nil
        await systemCapture.stop()
        await startSystemAudioStream(locale: settings.locale, vadManager: vadManager)

        Log.transcription.info("System audio stream restarted")
    }

    private func startMicStream(
        locale: Locale,
        vadManager: VadManager,
        deviceID: AudioDeviceID,
        echoCancellation: Bool = false
    ) {
        var micStream = micCapture.bufferStream(deviceID: deviceID, echoCancellation: echoCancellation)
        if let recorder = audioRecorder {
            micStream = Self.tappedStream(micStream) { buffer in
                recorder.writeMicBuffer(buffer)
            }
        }
        let store = transcriptStore
        guard let micTranscriber = makeTranscriber(
            locale: locale,
            speaker: .you,
            vadManager: vadManager,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        ) else {
            lastError = "Failed to create transcriber. Try restarting."
            isRunning = false
            assetStatus = "Ready"
            return
        }
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }
    }

    private func startSystemAudioStream(
        locale: Locale,
        vadManager: VadManager
    ) async {
        Log.transcription.info("Starting system audio capture")

        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            sysStreams = try await systemCapture.bufferStream()
            Log.transcription.info("System audio capture started")
            clearSystemAudioErrorIfPresent()
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            Log.transcription.error("Failed to start system audio: \(msg, privacy: .public)")
            lastError = msg
            return
        }

        var sysStream = sysStreams.systemAudio
        if let recorder = audioRecorder {
            sysStream = Self.tappedStream(sysStream) { buffer in
                recorder.writeSysBuffer(buffer)
            }
        }

        // Track cumulative audio time for diarizer speaker attribution
        let sysAudioTime = SyncDouble()

        // Tee system audio to diarization manager if enabled
        if let dm = diarizationManager {
            let diarFlushSize = 16000
            let originalSysStream = sysStream
            let (diarTapped, diarContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            Task {
                nonisolated(unsafe) let safeDm = dm
                var diarBuf: [Float] = []
                for await buffer in originalSysStream {
                    nonisolated(unsafe) let b = buffer
                    diarContinuation.yield(b)
                    guard let channelData = buffer.floatChannelData else { continue }
                    let frameCount = Int(buffer.frameLength)
                    sysAudioTime.add(Double(frameCount) / buffer.format.sampleRate)
                    diarBuf.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    if diarBuf.count >= diarFlushSize {
                        let batch = diarBuf
                        diarBuf.removeAll(keepingCapacity: true)
                        try? await safeDm.feedAudio(batch)
                    }
                }
                // Flush tail
                if !diarBuf.isEmpty {
                    try? await safeDm.feedAudio(diarBuf)
                }
                diarContinuation.finish()
            }
            sysStream = diarTapped
        }

        let store = transcriptStore
        guard let sysTranscriber = makeTranscriber(
            locale: locale,
            speaker: .them,
            vadManager: vadManager,
            onPartial: { text in
                Task { @MainActor in store.volatileThemText = text }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in
                    store.volatileThemText = ""
                    let speaker: Speaker
                    if let dm = self?.diarizationManager {
                        // Estimate segment time: each onFinal is ~3-5s of speech
                        let endTime = sysAudioTime.value
                        let startTime = max(0, endTime - 5.0)
                        speaker = await dm.dominantSpeaker(from: startTime, to: endTime)
                    } else {
                        speaker = .them
                    }
                    store.append(Utterance(text: text, speaker: speaker))
                }
            }
        ) else {
            lastError = "Failed to create the system-audio transcriber. Try restarting."
            return
        }

        sysTask = Task.detached {
            await sysTranscriber.run(stream: sysStream)
        }
    }

    private func makeTranscriber(
        locale: Locale,
        speaker: Speaker,
        vadManager: VadManager,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) -> StreamingTranscriber? {
        let backend = speaker == .you ? micBackend : systemBackend
        guard let backend else {
            Log.transcription.error("makeTranscriber called without initialized backend for \(speaker.storageKey, privacy: .public)")
            return nil
        }
        return StreamingTranscriber(
            backend: backend,
            locale: locale,
            vadManager: vadManager,
            speaker: speaker,
            flushInterval: settings.transcriptionModel.flushIntervalSamples,
            onPartial: onPartial,
            onFinal: onFinal
        )
    }

    private func resolvedMicDeviceID(for inputDeviceID: AudioDeviceID) -> AudioDeviceID? {
        if inputDeviceID > 0 {
            let availableDeviceIDs = Set(MicCapture.availableInputDevices().map(\.id))
            return availableDeviceIDs.contains(inputDeviceID) ? inputDeviceID : nil
        }

        return MicCapture.defaultInputDeviceID()
    }

    private func unavailableMicMessage(for inputDeviceID: AudioDeviceID) -> String {
        if inputDeviceID > 0 {
            return "The selected microphone is no longer available."
        }

        return "No default microphone is currently available."
    }

    private static func modelNeedsDownload(_ model: TranscriptionModel) -> Bool {
        let backend = model.makeBackend()
        if case .needsDownload = backend.checkStatus() {
            return true
        }
        return false
    }

    /// Wrap an audio stream to forward each buffer to a synchronous tap before yielding it downstream.
    private nonisolated static func tappedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AsyncStream<AVAudioPCMBuffer> {
        struct Box: @unchecked Sendable { let stream: AsyncStream<AVAudioPCMBuffer> }
        let box = Box(stream: stream)
        let (output, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        Task {
            for await buffer in box.stream {
                tap(buffer)
                nonisolated(unsafe) let b = buffer
                continuation.yield(b)
            }
            continuation.finish()
        }
        return output
    }

    private func localeMismatchMessage(
        for locale: Locale,
        transcriptionModel: TranscriptionModel
    ) -> String? {
        guard transcriptionModel == .parakeetV2,
              let languageCode = normalizedLanguageCode(for: locale),
              languageCode != "en"
        else {
            return nil
        }

        let localeIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return "Parakeet TDT v2 is English-only. Switch to Parakeet TDT v3 or Qwen3 ASR for \(localeIdentifier)."
    }

    private func normalizedLanguageCode(for locale: Locale) -> String? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-").first.map { String($0).lowercased() }
    }

    private func clearSystemAudioErrorIfPresent() {
        guard let lastError else { return }
        if lastError.localizedCaseInsensitiveContains("system audio") ||
            lastError.localizedCaseInsensitiveContains("audio output device") {
            self.lastError = nil
        }
    }

    // MARK: - Download Progress Detail

    private func updateDownloadDetail(fraction: Double) {
        guard let startTime = downloadStartTime else {
            downloadDetail = DownloadProgressDetail(fraction: fraction, sizeText: nil, speedText: nil, etaText: nil)
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let totalBytes = downloadTotalBytes

        // Size text: "142 MB / 800 MB" (only when total is known)
        var sizeText: String?
        if let totalBytes {
            let downloaded = Int64(fraction * Double(totalBytes))
            sizeText = "\(Self.formatBytes(downloaded)) / \(Self.formatBytes(totalBytes))"
        }

        // Speed and ETA need enough elapsed time to be meaningful
        var speedText: String?
        var etaText: String?
        if elapsed > 1, fraction > 0.01 {
            // Speed from fraction progress rate + known total
            if let totalBytes {
                let bytesDownloaded = fraction * Double(totalBytes)
                let bytesPerSecond = bytesDownloaded / elapsed
                speedText = "\(Self.formatBytes(Int64(bytesPerSecond)))/s"

                let remaining = Double(totalBytes) - bytesDownloaded
                if bytesPerSecond > 0 {
                    let secondsLeft = remaining / bytesPerSecond
                    etaText = Self.formatDuration(secondsLeft)
                }
            } else {
                // No total bytes known — estimate ETA from fraction rate alone
                let fractionPerSecond = fraction / elapsed
                if fractionPerSecond > 0 {
                    let remainingFraction = 1.0 - fraction
                    let secondsLeft = remainingFraction / fractionPerSecond
                    etaText = Self.formatDuration(secondsLeft)
                }
            }
        }

        downloadDetail = DownloadProgressDetail(
            fraction: fraction,
            sizeText: sizeText,
            speedText: speedText,
            etaText: etaText
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s remaining" }
        let m = s / 60
        let rem = s % 60
        return rem > 0 ? "\(m)m \(rem)s remaining" : "\(m)m remaining"
    }
}
