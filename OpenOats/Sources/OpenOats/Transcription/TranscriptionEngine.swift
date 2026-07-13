import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

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

/// Session-scoped transcription settings captured at start time.
struct ActiveTranscriptionSession: Sendable, Equatable {
    let sessionID: String?
    let transcriptionModel: TranscriptionModel

    init(sessionID: String? = nil, transcriptionModel: TranscriptionModel) {
        self.sessionID = sessionID
        self.transcriptionModel = transcriptionModel
    }

    var flushIntervalSamples: Int {
        transcriptionModel.flushIntervalSamples
    }

    func clearModelCache(
        using makeBackend: (TranscriptionModel) -> any TranscriptionBackend = { $0.makeBackend() }
    ) {
        guard !transcriptionModel.usesStreamingSession else { return }
        makeBackend(transcriptionModel).clearModelCache()
    }
}

/// Stops forwarding diarization samples after the first feed failure.
struct DiarizationFeedRelay: Sendable {
    private(set) var hasFailed = false

    mutating func feedAudio(
        _ samples: [Float],
        into feedAudio: @Sendable ([Float]) async throws -> Void,
        onFailure: @Sendable (Error) async -> Void
    ) async {
        guard !hasFailed else { return }

        do {
            try await feedAudio(samples)
        } catch {
            hasFailed = true
            await onFailure(error)
        }
    }
}

struct CaptureHealthSnapshot: Sendable, Equatable {
    let micHasCapturedFrames: Bool
    let systemHasCapturedFrames: Bool
    let micCaptureError: String?
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    struct StartPreflightIssue: Equatable {
        let message: String
    }

    enum MicStartupHealthAction: Equatable {
        case none
        case retryCapture
        case showNoAudioError
    }

    private struct PreparedCloudStartBackend {
        let model: TranscriptionModel
        let backend: any TranscriptionBackend
    }

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

    @ObservationIgnored nonisolated(unsafe) private var _liveCloudTranscriptIssue: CloudTranscriptCopy.Presentation?
    var liveCloudTranscriptIssue: CloudTranscriptCopy.Presentation? {
        get { access(keyPath: \.liveCloudTranscriptIssue); return _liveCloudTranscriptIssue }
        set { withMutation(keyPath: \.liveCloudTranscriptIssue) { _liveCloudTranscriptIssue = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _liveCloudTranscriptionIsProcessing = false
    var liveCloudTranscriptionIsProcessing: Bool {
        get { access(keyPath: \.liveCloudTranscriptionIsProcessing); return _liveCloudTranscriptionIsProcessing }
        set { withMutation(keyPath: \.liveCloudTranscriptionIsProcessing) { _liveCloudTranscriptionIsProcessing = newValue } }
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

    /// Pause/resume all recording. When paused, neither mic nor system audio
    /// is transcribed and audio levels read as 0.
    nonisolated var isRecordingPaused: Bool {
        get { micCapture.isPaused }
        set {
            micCapture.isPaused = newValue
            systemCapture.isPaused = newValue
        }
    }

    nonisolated var captureHealthSnapshot: CaptureHealthSnapshot {
        CaptureHealthSnapshot(
            micHasCapturedFrames: micCapture.hasCapturedFrames,
            systemHasCapturedFrames: systemCapture.hasCapturedFrames,
            micCaptureError: micCapture.captureError
        )
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

    private var streamingProvider: (any StreamingTranscriptionProvider)?
    private var micStreamingSession: (any StreamingTranscriptionSession)?
    private var systemStreamingSession: (any StreamingTranscriptionSession)?

    /// Audio recorder for tapping streams (set by ContentView when recording is enabled).
    var audioRecorder: AudioRecorder?

    /// Speaker diarization manager for system audio (nil when diarization is disabled).
    private var diarizationManager: DiarizationManager?

    /// Active transcription model captured for the current session/startup.
    @ObservationIgnored nonisolated(unsafe) var activeTranscriptionSession: ActiveTranscriptionSession?
    @ObservationIgnored private var preparedCloudStartBackend: PreparedCloudStartBackend?

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
            if settings.transcriptionModel.usesStreamingSession {
                Task { @MainActor [weak self] in
                    await self?.refreshStreamingDownloadStatus()
                }
            }
        case .scripted:
            self.needsModelDownload = false
        }
    }

    static func micStartupHealthAction(
        hasCapturedFrames: Bool,
        captureError: String?,
        hasRetried: Bool
    ) -> MicStartupHealthAction {
        guard !hasCapturedFrames, captureError == nil else { return .none }
        return hasRetried ? .showNoAudioError : .retryCapture
    }

    nonisolated static func shouldLoadVAD(for model: TranscriptionModel) -> Bool {
        !model.usesStreamingSession
    }

    func refreshModelAvailability() {
        switch mode {
        case .live:
            if settings.transcriptionModel.usesStreamingSession {
                // Sync path cannot query Speech assets; refresh asynchronously.
                needsModelDownload = false
                Task { @MainActor [weak self] in
                    await self?.refreshStreamingDownloadStatus()
                }
            } else {
                needsModelDownload = Self.modelNeedsDownload(settings.transcriptionModel)
            }
        case .scripted:
            needsModelDownload = false
        }
    }

    func preflightStart(transcriptionModel: TranscriptionModel) async -> StartPreflightIssue? {
        guard case .live = mode else { return nil }

        lastError = nil
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil

        if let inputIssue = validateConfiguredInputDevice() {
            lastError = inputIssue.message
            assetStatus = "Ready"
            return inputIssue
        }

        if let outputIssue = validateConfiguredOutputDevice() {
            lastError = outputIssue.message
            assetStatus = "Ready"
            return outputIssue
        }

        guard transcriptionModel.isCloud else {
            assetStatus = "Ready"
            return nil
        }

        let apiKey = settings.cloudASRApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            let issue = StartPreflightIssue(
                message: "Missing \(transcriptionModel.displayName) API key. Check Settings > Transcription."
            )
            lastError = issue.message
            assetStatus = "Ready"
            return issue
        }

        assetStatus = "Validating \(transcriptionModel.displayName)..."

        do {
            let backend = transcriptionModel.makeBackend(
                customVocabulary: settings.transcriptionCustomVocabulary,
                apiKey: apiKey,
                removeFillerWords: settings.removeFillerWords
            )
            try await prepareBackend(backend)
            preparedCloudStartBackend = PreparedCloudStartBackend(model: transcriptionModel, backend: backend)
            assetStatus = "Ready"
            return nil
        } catch let error as CloudASRError {
            assetStatus = "Ready"
            switch error {
            case .invalidAPIKey:
                let issue = StartPreflightIssue(message: error.localizedDescription)
                lastError = issue.message
                return issue
            default:
                Log.transcription.error(
                    "Cloud start preflight validation fell back to runtime start after non-blocking error: \(error, privacy: .public)"
                )
                lastError = nil
                return nil
            }
        } catch {
            assetStatus = "Ready"
            Log.transcription.error(
                "Cloud start preflight validation fell back to runtime start after unexpected error: \(error, privacy: .public)"
            )
            lastError = nil
            return nil
        }
    }

    /// Download the model without starting a transcription session.
    func downloadModelOnly(transcriptionModel: TranscriptionModel) async {
        guard !isRunning, downloadProgress == nil else { return }

        refreshModelAvailability()
        guard needsModelDownload else { return }

        lastError = nil
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        assetStatus = "Downloading \(transcriptionModel.displayName)..."
        beginDownloadTracking(for: transcriptionModel)

        do {
            if transcriptionModel.usesStreamingSession {
                guard let provider = transcriptionModel.makeStreamingProvider() else {
                    lastError = StreamingTranscriptionError.unsupportedOnThisOS.localizedDescription
                    assetStatus = "Ready"
                    clearDownloadTracking()
                    return
                }
                try await prepareStreamingProvider(provider, locale: settings.locale)
            } else {
                let vocab = settings.transcriptionCustomVocabulary
                let backend = transcriptionModel.makeBackend(customVocabulary: vocab)
                try await prepareBackend(backend)
            }
            needsModelDownload = false
            downloadConfirmed = false
            clearDownloadTracking()
            assetStatus = "Ready"
        } catch is CancellationError {
            clearDownloadTracking()
            assetStatus = "Ready"
        } catch {
            lastError = "Failed to download: \(error.localizedDescription)"
            assetStatus = "Ready"
            clearDownloadTracking()
            if !transcriptionModel.usesStreamingSession {
                transcriptionModel.makeBackend().clearModelCache()
            }
            needsModelDownload = true
        }
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        transcriptionModel: TranscriptionModel,
        sessionID: String? = nil
    ) async {
        Log.transcription.info("start() called, isRunning=\(self.isRunning, privacy: .public)")
        guard !isRunning, downloadProgress == nil else { return }
        lastError = nil
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
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

        activeTranscriptionSession = ActiveTranscriptionSession(
            sessionID: sessionID,
            transcriptionModel: transcriptionModel
        )

        guard await ensureMicrophonePermission() else {
            activeTranscriptionSession = nil
            return
        }

        isRunning = true

        // 1. Load transcription models via backend protocol
        let isDownloading = needsModelDownload
        assetStatus = isDownloading
            ? "Downloading \(transcriptionModel.displayName)..."
            : "Loading \(transcriptionModel.displayName)..."
        if isDownloading {
            beginDownloadTracking(for: transcriptionModel)
        }
        Log.transcription.info("Loading transcription model \(transcriptionModel.rawValue, privacy: .public)")
        let usesStreaming = transcriptionModel.usesStreamingSession
        do {
            if usesStreaming {
                guard let provider = transcriptionModel.makeStreamingProvider() else {
                    lastError = StreamingTranscriptionError.unsupportedOnThisOS.localizedDescription
                    assetStatus = "Ready"
                    isRunning = false
                    clearDownloadTracking()
                    downloadConfirmed = false
                    activeTranscriptionSession = nil
                    return
                }
                try await prepareStreamingProvider(provider, locale: locale)
                streamingProvider = provider

                if settings.enableDiarization {
                    Log.transcription.info("Diarization is ignored when using Apple SpeechAnalyzer")
                }
                diarizationManager = nil
                vadManager = nil
                micBackend = nil
                systemBackend = nil
            } else {
                let vocab = settings.transcriptionCustomVocabulary
                let apiKey = settings.cloudASRApiKey
                let noFiller = settings.removeFillerWords
                let mic: any TranscriptionBackend
                if transcriptionModel.isCloud,
                   let preparedCloudStartBackend,
                   preparedCloudStartBackend.model == transcriptionModel {
                    mic = preparedCloudStartBackend.backend
                    self.preparedCloudStartBackend = nil
                } else {
                    mic = transcriptionModel.makeBackend(
                        customVocabulary: vocab,
                        apiKey: apiKey,
                        removeFillerWords: noFiller
                    )
                    try await prepareBackend(mic)
                }
                self.micBackend = mic

                // Parakeet needs a separate backend for system audio (mutable decoder state).
                // Qwen3 is actor-based and thread-safe, so reuse the same instance.
                if transcriptionModel == .qwen3ASR06B || transcriptionModel.isCloud {
                    self.systemBackend = mic
                } else {
                    let sys = transcriptionModel.makeBackend(customVocabulary: vocab, apiKey: apiKey, removeFillerWords: noFiller)
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
            }

            needsModelDownload = false
            downloadConfirmed = false
            clearDownloadTracking()
            assetStatus = "Models ready"
            Log.transcription.info("Transcription model loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            Log.transcription.error("Failed to load models: \(error, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            clearDownloadTracking()
            streamingProvider = nil
            // Clear corrupt cache so the next attempt triggers a fresh download.
            // Cloud models don't have local caches or download flows.
            if !transcriptionModel.isCloud {
                activeTranscriptionSession?.clearModelCache()
                Log.transcription.info(
                    "Cleared model cache for \(transcriptionModel.rawValue, privacy: .public)"
                )
                needsModelDownload = true
            }
            downloadConfirmed = false
            activeTranscriptionSession = nil
            return
        }

        if !usesStreaming {
            guard vadManager != nil else {
                activeTranscriptionSession = nil
                return
            }
        }

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        guard let targetMicID = resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = unavailableMicMessage(for: inputDeviceID)
            Log.transcription.error("Mic unavailable: \(msg, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            streamingProvider = nil
            activeTranscriptionSession = nil
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
        if usesStreaming {
            do {
                try await startMicStreamingSession(
                    locale: locale,
                    deviceID: targetMicID,
                    echoCancellation: useAEC
                )
            } catch {
                Log.transcription.error("Failed to start mic streaming session: \(error, privacy: .public)")
                lastError = error.localizedDescription
                assetStatus = "Ready"
                isRunning = false
                micCapture.finishStream()
                await tearDownStreamingSessions()
                await micTask?.value
                micCapture.stop()
                micTask = nil
                streamingProvider = nil
                activeTranscriptionSession = nil
                return
            }
        } else if let vadManager {
            startMicStream(
                locale: locale,
                vadManager: vadManager,
                deviceID: targetMicID,
                echoCancellation: useAEC
            )
        }

        // Check for immediate mic capture failure
        if let micError = micCapture.captureError {
            Log.transcription.error("Mic capture error: \(micError, privacy: .public)")
            lastError = micError
        }

        // Health check: if mic produces no audio within 5 seconds, retry once.
        // This covers first-start device initialization races that users otherwise fix by stopping/restarting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning else { return }

            switch Self.micStartupHealthAction(
                hasCapturedFrames: self.micCapture.hasCapturedFrames,
                captureError: self.micCapture.captureError,
                hasRetried: false
            ) {
            case .none:
                return
            case .showNoAudioError:
                Log.transcription.error("No mic audio after 5s")
                self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
            case .retryCapture:
                Log.transcription.error("No mic audio after 5s, retrying mic capture once")
                if self.streamingProvider != nil {
                    await self.micStreamingSession?.finish()
                    self.micStreamingSession = nil
                    self.micCapture.finishStream()
                    await self.micTask?.value
                    self.micTask = nil
                    self.micCapture.stop()
                    do {
                        try await self.startMicStreamingSession(
                            locale: locale,
                            deviceID: targetMicID,
                            echoCancellation: false
                        )
                    } catch {
                        Log.transcription.error("Mic streaming retry failed: \(error, privacy: .public)")
                        self.lastError = error.localizedDescription
                        return
                    }
                } else if let vadManager = self.vadManager {
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
                    return
                }

                try? await Task.sleep(for: .seconds(5))
                guard self.isRunning else { return }
                if let micError = self.micCapture.captureError {
                    Log.transcription.error("Mic capture error after retry: \(micError, privacy: .public)")
                    self.lastError = micError
                    return
                }
                if Self.micStartupHealthAction(
                    hasCapturedFrames: self.micCapture.hasCapturedFrames,
                    captureError: self.micCapture.captureError,
                    hasRetried: true
                ) == .showNoAudioError {
                    Log.transcription.error("No mic audio after retry")
                    self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
                }
            }
        }

        // 3. Start system audio capture
        if usesStreaming {
            do {
                try await startSystemAudioStreamingSession(locale: locale)
            } catch {
                Log.transcription.error("Failed to start system streaming session: \(error, privacy: .public)")
                lastError = error.localizedDescription
                assetStatus = "Ready"
                isRunning = false
                micCapture.finishStream()
                systemCapture.finishStream()
                await tearDownStreamingSessions()
                micTask?.cancel()
                sysTask?.cancel()
                await micTask?.value
                await sysTask?.value
                micCapture.stop()
                await systemCapture.stop()
                micTask = nil
                sysTask = nil
                streamingProvider = nil
                activeTranscriptionSession = nil
                return
            }
        } else if let vadManager {
            await startSystemAudioStream(locale: locale, vadManager: vadManager)
        }

        let displayName = streamingProvider?.displayName
            ?? micBackend?.displayName
            ?? transcriptionModel.displayName
        assetStatus = "Transcribing (\(displayName))"
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
            activeTranscriptionSession = nil
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

        await micStreamingSession?.finish()
        await systemStreamingSession?.finish()
        micStreamingSession = nil
        systemStreamingSession = nil

        micTask?.cancel()
        sysTask?.cancel()
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
        vadManager = nil
        streamingProvider = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil
        activeTranscriptionSession = nil
        isRunning = false
        assetStatus = "Ready"
    }

    func stop() {
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            liveCloudTranscriptIssue = nil
            liveCloudTranscriptionIsProcessing = false
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
        let micSession = micStreamingSession
        let sysSession = systemStreamingSession
        micStreamingSession = nil
        systemStreamingSession = nil
        streamingProvider = nil
        if micSession != nil || sysSession != nil {
            Task {
                await micSession?.finish()
                await sysSession?.finish()
            }
        }
        Task { await systemCapture.stop() }
        micCapture.stop()
        currentMicDeviceID = 0
        micBackend = nil
        systemBackend = nil
        vadManager = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil
        activeTranscriptionSession = nil
        isRunning = false
        assetStatus = "Ready"
    }

    private func performMicRestart(inputDeviceID: AudioDeviceID) async {
        guard isRunning else { return }

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

        if streamingProvider != nil {
            await micStreamingSession?.finish()
            micStreamingSession = nil
            micCapture.finishStream()
            await micTask?.value

            if Task.isCancelled || !isRunning {
                return
            }

            micTask = nil
            micCapture.stop()

            guard await ensureMicrophonePermission() else {
                Log.transcription.error("Mic permission lost during device switch")
                return
            }

            do {
                try await startMicStreamingSession(
                    locale: settings.locale,
                    deviceID: targetMicID
                )
                currentMicDeviceID = targetMicID
                lastError = nil
                Log.transcription.info("Mic restarted on device \(targetMicID, privacy: .public)")
            } catch {
                Log.transcription.error("Mic streaming restart failed: \(error, privacy: .public)")
                lastError = error.localizedDescription
            }
            return
        }

        guard let vadManager else { return }

        micCapture.finishStream()
        await micTask?.value

        if Task.isCancelled || !isRunning {
            return
        }

        micTask = nil
        micCapture.stop()

        guard await ensureMicrophonePermission() else {
            Log.transcription.error("Mic permission lost during device switch")
            return
        }

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
        guard isRunning else { return }

        Log.transcription.info("Restarting system audio stream")

        if streamingProvider != nil {
            await systemStreamingSession?.finish()
            systemStreamingSession = nil
            systemCapture.finishStream()
            await sysTask?.value

            if Task.isCancelled || !isRunning {
                return
            }

            sysTask = nil
            await systemCapture.stop()
            do {
                try await startSystemAudioStreamingSession(locale: settings.locale)
                Log.transcription.info("System audio stream restarted")
            } catch {
                Log.transcription.error("System streaming restart failed: \(error, privacy: .public)")
                lastError = error.localizedDescription
            }
            return
        }

        guard let vadManager else { return }

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

    private func startMicStreamingSession(
        locale: Locale,
        deviceID: AudioDeviceID,
        echoCancellation: Bool = false
    ) async throws {
        guard let provider = streamingProvider else {
            throw StreamingTranscriptionError.notPrepared
        }

        var micStream = micCapture.bufferStream(deviceID: deviceID, echoCancellation: echoCancellation)
        if let recorder = audioRecorder {
            micStream = Self.tappedStream(micStream) { buffer in
                recorder.writeMicBuffer(buffer)
            }
        }

        let session = try await provider.makeSession(locale: locale)
        micStreamingSession = session
        let store = transcriptStore
        micTask = Task.detached {
            await session.run(
                stream: micStream,
                onPartial: { text in
                    Task { @MainActor in store.volatileYouText = text }
                },
                onFinal: { segment in
                    Task { @MainActor in
                        store.volatileYouText = ""
                        store.append(Utterance(text: segment.text, speaker: .you))
                    }
                }
            )
        }
    }

    private func startSystemAudioStreamingSession(locale: Locale) async throws {
        guard let provider = streamingProvider else {
            throw StreamingTranscriptionError.notPrepared
        }

        Log.transcription.info("Starting system audio capture")

        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            var outputID: AudioDeviceID? = settings.outputDeviceID != 0 ? settings.outputDeviceID : nil
            // If the stored ID is stale, try resolving via stable UID.
            if let id = outputID,
               !SystemAudioCapture.availableOutputDevices().contains(where: { $0.id == id }),
               let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
                outputID = resolved
            }
            sysStreams = try await systemCapture.bufferStream(outputDeviceID: outputID)
            Log.transcription.info("System audio capture started")
            clearSystemAudioErrorIfPresent()
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            Log.transcription.error("Failed to start system audio: \(error, privacy: .public)")
            lastError = msg
            throw error
        }

        var sysStream = sysStreams.systemAudio
        if let recorder = audioRecorder {
            sysStream = Self.tappedStream(sysStream) { buffer in
                recorder.writeSysBuffer(buffer)
            }
        }

        let session = try await provider.makeSession(locale: locale)
        systemStreamingSession = session
        let store = transcriptStore
        sysTask = Task.detached {
            await session.run(
                stream: sysStream,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { segment in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: segment.text, speaker: .them))
                    }
                }
            )
        }
    }

    private func tearDownStreamingSessions() async {
        await micStreamingSession?.finish()
        await systemStreamingSession?.finish()
        micStreamingSession = nil
        systemStreamingSession = nil
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
            onFinal: { segment in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: segment.text, speaker: .you))
                }
            }
        ) else {
            lastError = "Failed to create transcriber. Try restarting."
            isRunning = false
            assetStatus = "Ready"
            activeTranscriptionSession = nil
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
            var outputID: AudioDeviceID? = settings.outputDeviceID != 0 ? settings.outputDeviceID : nil
            // If the stored ID is stale, try resolving via stable UID.
            if let id = outputID,
               !SystemAudioCapture.availableOutputDevices().contains(where: { $0.id == id }),
               let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
                outputID = resolved
            }
            sysStreams = try await systemCapture.bufferStream(outputDeviceID: outputID)
            Log.transcription.info("System audio capture started")
            clearSystemAudioErrorIfPresent()
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            Log.transcription.error("Failed to start system audio: \(error, privacy: .public)")
            lastError = msg
            return
        }

        var sysStream = sysStreams.systemAudio
        if let recorder = audioRecorder {
            sysStream = Self.tappedStream(sysStream) { buffer in
                recorder.writeSysBuffer(buffer)
            }
        }

        // Tee system audio to diarization manager if enabled
        if let dm = diarizationManager {
            let diarFlushSize = 16000
            let originalSysStream = sysStream
            let (diarTapped, diarContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            Task {
                let safeDm = dm
                var diarizationRelay = DiarizationFeedRelay()
                var diarBuf: [Float] = []
                for await buffer in originalSysStream {
                    nonisolated(unsafe) let b = buffer
                    diarContinuation.yield(b)
                    guard let channelData = buffer.floatChannelData else { continue }
                    let frameCount = Int(buffer.frameLength)
                    diarBuf.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    if diarBuf.count >= diarFlushSize {
                        let batch = diarBuf
                        diarBuf.removeAll(keepingCapacity: true)
                        await diarizationRelay.feedAudio(
                            batch,
                            into: { samples in try await safeDm.feedAudio(samples) },
                            onFailure: { error in
                                Log.transcription.error(
                                    "Diarization feed failed: \(error, privacy: .public)"
                                )
                            }
                        )
                    }
                }
                // Flush tail
                if !diarBuf.isEmpty {
                    await diarizationRelay.feedAudio(
                        diarBuf,
                        into: { samples in try await safeDm.feedAudio(samples) },
                        onFailure: { error in
                            Log.transcription.error(
                                "Diarization feed failed: \(error, privacy: .public)"
                            )
                        }
                    )
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
            onFinal: { [weak self] segment in
                Task { @MainActor in
                    store.volatileThemText = ""
                    let speaker: Speaker
                    if let dm = self?.diarizationManager {
                        speaker = await dm.dominantSpeaker(from: segment.startTime, to: segment.endTime)
                    } else {
                        speaker = .them
                    }
                    store.append(Utterance(text: segment.text, speaker: speaker))
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
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void
    ) -> StreamingTranscriber? {
        let backend = speaker == .you ? micBackend : systemBackend
        guard let backend else {
            Log.transcription.error("makeTranscriber called without initialized backend for \(speaker.storageKey, privacy: .public)")
            return nil
        }
        let model = currentTranscriptionModel()
        return StreamingTranscriber(
            backend: backend,
            locale: locale,
            vadManager: vadManager,
            speaker: speaker,
            sessionID: activeTranscriptionSession?.sessionID,
            transcriptionModel: model.rawValue,
            flushInterval: model.flushIntervalSamples,
            skipPartials: model.isCloud,
            onPartial: onPartial,
            onFinal: onFinal,
            onCloudSegmentStatus: makeCloudSegmentStatusHandler(for: model),
            onCloudProcessingChanged: makeCloudProcessingChangedHandler(for: model)
        )
    }

    private func makeCloudSegmentStatusHandler(
        for model: TranscriptionModel
    ) -> (@Sendable (StreamingTranscriber.CloudSegmentStatus) -> Void)? {
        guard model.isCloud else { return nil }
        return { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleCloudSegmentStatus(status)
            }
        }
    }

    private func makeCloudProcessingChangedHandler(
        for model: TranscriptionModel
    ) -> (@Sendable (Bool) -> Void)? {
        guard model.isCloud else { return nil }
        return { [weak self] isProcessing in
            Task { @MainActor [weak self] in
                self?.liveCloudTranscriptionIsProcessing = isProcessing
            }
        }
    }

    private func handleCloudSegmentStatus(_ status: StreamingTranscriber.CloudSegmentStatus) {
        switch status.kind {
        case .success:
            liveCloudTranscriptIssue = nil
        case .empty:
            if transcriptStore.utterances.isEmpty {
                liveCloudTranscriptIssue = status.presentation
            }
        case .error:
            liveCloudTranscriptIssue = status.presentation
            if let presentation = status.presentation,
               presentation.title.localizedCaseInsensitiveContains("API key rejected") {
                lastError = "\(presentation.title). \(presentation.detail)"
            }
        }
    }

    func currentTranscriptionModel() -> TranscriptionModel {
        activeTranscriptionSession?.transcriptionModel ?? settings.transcriptionModel
    }

    private func resolvedMicDeviceID(for inputDeviceID: AudioDeviceID) -> AudioDeviceID? {
        if inputDeviceID > 0 {
            let availableDeviceIDs = Set(MicCapture.availableInputDevices().map(\.id))
            if availableDeviceIDs.contains(inputDeviceID) { return inputDeviceID }
            // Device ID is stale; try resolving via stable UID.
            if let uid = settings.inputDeviceUID,
               let resolved = MicCapture.inputDeviceID(forUID: uid) {
                // Update the stored ID so future lookups are fast.
                settings.inputDeviceID = resolved
                return resolved
            }
            return nil
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
        guard !model.isCloud else { return false }
        if model.usesStreamingSession {
            // Speech asset status is async (AssetInventory / installedLocales).
            // Never force-true here — that blocked Live start with a silent return
            // and left the UI in .recording with no capture. Async refresh sets
            // needsModelDownload from StreamingTranscriptionProvider.checkStatus.
            return false
        }
        let backend = model.makeBackend()
        if case .needsDownload = backend.checkStatus() {
            return true
        }
        return false
    }

    private func refreshStreamingDownloadStatus() async {
        let model = settings.transcriptionModel
        guard model.usesStreamingSession else { return }
        guard let provider = model.makeStreamingProvider() else {
            needsModelDownload = false
            return
        }

        let status = await provider.checkStatus(locale: settings.locale)
        let needsDownload: Bool
        if case .needsDownload = status {
            needsDownload = true
        } else {
            needsDownload = false
        }
        needsModelDownload = needsDownload
    }

    private func validateConfiguredInputDevice() -> StartPreflightIssue? {
        guard settings.inputDeviceID > 0 else {
            guard MicCapture.defaultInputDeviceID() != nil else {
                return StartPreflightIssue(
                    message: "No default microphone is currently available."
                )
            }
            return nil
        }

        if MicCapture.availableInputDevices().contains(where: { $0.id == settings.inputDeviceID }) {
            return nil
        }
        if let uid = settings.inputDeviceUID,
           let resolved = MicCapture.inputDeviceID(forUID: uid) {
            settings.inputDeviceID = resolved
            return nil
        }

        return StartPreflightIssue(
            message: "The selected microphone is no longer available. Choose another microphone in Settings > Transcription."
        )
    }

    private func validateConfiguredOutputDevice() -> StartPreflightIssue? {
        var configuredOutputID: AudioDeviceID? = settings.outputDeviceID != 0 ? settings.outputDeviceID : nil

        if let id = configuredOutputID {
            if SystemAudioCapture.availableOutputDevices().contains(where: { $0.id == id }) {
                return nil
            }
            if let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
                configuredOutputID = resolved
            } else {
                return StartPreflightIssue(
                    message: "The selected output device is no longer available. Choose another output device in Settings > Transcription."
                )
            }
        }

        if configuredOutputID == nil {
            do {
                _ = try SystemAudioCapture.defaultOutputDeviceID()
            } catch SystemAudioCapture.CaptureError.noOutputDevice {
                return StartPreflightIssue(
                    message: "No system audio output device is currently available."
                )
            } catch {
                logOutputValidationFallback(error)
            }
        }

        return nil
    }

    private func logOutputValidationFallback(_ error: Error) {
        Log.transcription.error(
            "Output-device preflight validation fell back to runtime start after unexpected error: \(error, privacy: .public)"
        )
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

    // MARK: - Download Helpers

    private func beginDownloadTracking(for model: TranscriptionModel) {
        downloadProgress = 0
        downloadStartTime = Date()
        downloadTotalBytes = model.estimatedDownloadBytes
        downloadDetail = DownloadProgressDetail(fraction: 0, sizeText: nil, speedText: nil, etaText: nil)
    }

    private func clearDownloadTracking() {
        downloadProgress = nil
        downloadDetail = nil
        downloadStartTime = nil
        downloadTotalBytes = nil
    }

    private func prepareBackend(_ backend: any TranscriptionBackend) async throws {
        try await backend.prepare(
            onStatus: { [weak self] status in
                Task { @MainActor in self?.assetStatus = status }
            },
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.updateDownloadDetail(fraction: fraction)
                }
            }
        )
    }

    private func prepareStreamingProvider(
        _ provider: any StreamingTranscriptionProvider,
        locale: Locale
    ) async throws {
        try await provider.prepare(
            locale: locale,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.assetStatus = status }
            },
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.updateDownloadDetail(fraction: fraction)
                }
            }
        )
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
