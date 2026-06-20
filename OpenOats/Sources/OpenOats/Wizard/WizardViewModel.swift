@preconcurrency import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class WizardViewModel {
    // MARK: - Navigation State

    @ObservationIgnored nonisolated(unsafe) private var _currentStep: WizardStep = .intent
    var currentStep: WizardStep {
        get { access(keyPath: \.currentStep); return _currentStep }
        set { withMutation(keyPath: \.currentStep) { _currentStep = newValue } }
    }

    /// The ordered path the user has taken for back-navigation.
    @ObservationIgnored nonisolated(unsafe) private var _stepHistory: [WizardStep] = [.intent]
    var stepHistory: [WizardStep] {
        get { access(keyPath: \.stepHistory); return _stepHistory }
        set { withMutation(keyPath: \.stepHistory) { _stepHistory = newValue } }
    }

    // MARK: - User Answers

    @ObservationIgnored nonisolated(unsafe) private var _intent: WizardIntent?
    var intent: WizardIntent? {
        get { access(keyPath: \.intent); return _intent }
        set {
            withMutation(keyPath: \.intent) { _intent = newValue }
            recomputeIfNeeded()
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _language: WizardLanguage?
    var language: WizardLanguage? {
        get { access(keyPath: \.language); return _language }
        set {
            withMutation(keyPath: \.language) { _language = newValue }
            recomputeIfNeeded()
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _privacy: WizardPrivacy?
    var privacy: WizardPrivacy? {
        get { access(keyPath: \.privacy); return _privacy }
        set {
            withMutation(keyPath: \.privacy) { _privacy = newValue }
            recomputeIfNeeded()
        }
    }

    // MARK: - API Key Input

    @ObservationIgnored nonisolated(unsafe) private var _openRouterKeyInput = ""
    var openRouterKeyInput: String {
        get { access(keyPath: \.openRouterKeyInput); return _openRouterKeyInput }
        set {
            withMutation(keyPath: \.openRouterKeyInput) { _openRouterKeyInput = newValue }
            if !newValue.isEmpty {
                validateOpenRouterKey()
            } else {
                openRouterValidationTask?.cancel()
                openRouterValidation = nil
                isValidatingOpenRouter = false
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _voyageKeyInput = ""
    var voyageKeyInput: String {
        get { access(keyPath: \.voyageKeyInput); return _voyageKeyInput }
        set {
            withMutation(keyPath: \.voyageKeyInput) { _voyageKeyInput = newValue }
            if !newValue.isEmpty {
                validateVoyageKey()
            } else {
                voyageValidationTask?.cancel()
                voyageValidation = nil
                isValidatingVoyage = false
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assemblyAIKeyInput = ""
    var assemblyAIKeyInput: String {
        get { access(keyPath: \.assemblyAIKeyInput); return _assemblyAIKeyInput }
        set {
            withMutation(keyPath: \.assemblyAIKeyInput) { _assemblyAIKeyInput = newValue }
            if !newValue.isEmpty {
                validateAssemblyAIKey()
            } else {
                assemblyAIValidationTask?.cancel()
                assemblyAIValidation = nil
                isValidatingAssemblyAI = false
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _elevenLabsKeyInput = ""
    var elevenLabsKeyInput: String {
        get { access(keyPath: \.elevenLabsKeyInput); return _elevenLabsKeyInput }
        set {
            withMutation(keyPath: \.elevenLabsKeyInput) { _elevenLabsKeyInput = newValue }
            if !newValue.isEmpty {
                validateElevenLabsKey()
            } else {
                elevenLabsValidationTask?.cancel()
                elevenLabsValidation = nil
                isValidatingElevenLabs = false
            }
        }
    }

    // MARK: - Validation State

    @ObservationIgnored nonisolated(unsafe) private var _openRouterValidation: APIKeyValidator.ValidationResult?
    var openRouterValidation: APIKeyValidator.ValidationResult? {
        get { access(keyPath: \.openRouterValidation); return _openRouterValidation }
        set { withMutation(keyPath: \.openRouterValidation) { _openRouterValidation = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _voyageValidation: APIKeyValidator.ValidationResult?
    var voyageValidation: APIKeyValidator.ValidationResult? {
        get { access(keyPath: \.voyageValidation); return _voyageValidation }
        set { withMutation(keyPath: \.voyageValidation) { _voyageValidation = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assemblyAIValidation: APIKeyValidator.ValidationResult?
    var assemblyAIValidation: APIKeyValidator.ValidationResult? {
        get { access(keyPath: \.assemblyAIValidation); return _assemblyAIValidation }
        set { withMutation(keyPath: \.assemblyAIValidation) { _assemblyAIValidation = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _elevenLabsValidation: APIKeyValidator.ValidationResult?
    var elevenLabsValidation: APIKeyValidator.ValidationResult? {
        get { access(keyPath: \.elevenLabsValidation); return _elevenLabsValidation }
        set { withMutation(keyPath: \.elevenLabsValidation) { _elevenLabsValidation = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isValidatingOpenRouter = false
    var isValidatingOpenRouter: Bool {
        get { access(keyPath: \.isValidatingOpenRouter); return _isValidatingOpenRouter }
        set { withMutation(keyPath: \.isValidatingOpenRouter) { _isValidatingOpenRouter = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isValidatingVoyage = false
    var isValidatingVoyage: Bool {
        get { access(keyPath: \.isValidatingVoyage); return _isValidatingVoyage }
        set { withMutation(keyPath: \.isValidatingVoyage) { _isValidatingVoyage = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isValidatingAssemblyAI = false
    var isValidatingAssemblyAI: Bool {
        get { access(keyPath: \.isValidatingAssemblyAI); return _isValidatingAssemblyAI }
        set { withMutation(keyPath: \.isValidatingAssemblyAI) { _isValidatingAssemblyAI = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isValidatingElevenLabs = false
    var isValidatingElevenLabs: Bool {
        get { access(keyPath: \.isValidatingElevenLabs); return _isValidatingElevenLabs }
        set { withMutation(keyPath: \.isValidatingElevenLabs) { _isValidatingElevenLabs = newValue } }
    }

    // MARK: - Ollama State

    @ObservationIgnored nonisolated(unsafe) private var _ollamaStatus: OllamaStatus = .notReachable
    var ollamaStatus: OllamaStatus {
        get { access(keyPath: \.ollamaStatus); return _ollamaStatus }
        set { withMutation(keyPath: \.ollamaStatus) { _ollamaStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaPullProgress: Double?
    var ollamaPullProgress: Double? {
        get { access(keyPath: \.ollamaPullProgress); return _ollamaPullProgress }
        set { withMutation(keyPath: \.ollamaPullProgress) { _ollamaPullProgress = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaPullError: String?
    var ollamaPullError: String? {
        get { access(keyPath: \.ollamaPullError); return _ollamaPullError }
        set { withMutation(keyPath: \.ollamaPullError) { _ollamaPullError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isPullingModel = false
    var isPullingModel: Bool {
        get { access(keyPath: \.isPullingModel); return _isPullingModel }
        set { withMutation(keyPath: \.isPullingModel) { _isPullingModel = newValue } }
    }

    // MARK: - Mic Permission

    @ObservationIgnored nonisolated(unsafe) private var _micPermission: MicPermissionStatus = .notDetermined
    var micPermission: MicPermissionStatus {
        get { access(keyPath: \.micPermission); return _micPermission }
        set { withMutation(keyPath: \.micPermission) { _micPermission = newValue } }
    }

    // MARK: - Detection

    @ObservationIgnored nonisolated(unsafe) private var _snapshot: SetupSnapshot = .empty
    var snapshot: SetupSnapshot {
        get { access(keyPath: \.snapshot); return _snapshot }
        set { withMutation(keyPath: \.snapshot) { _snapshot = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isDetecting = true
    var isDetecting: Bool {
        get { access(keyPath: \.isDetecting); return _isDetecting }
        set { withMutation(keyPath: \.isDetecting) { _isDetecting = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isReconfiguration = false
    var isReconfiguration: Bool {
        get { access(keyPath: \.isReconfiguration); return _isReconfiguration }
        set { withMutation(keyPath: \.isReconfiguration) { _isReconfiguration = newValue } }
    }

    // MARK: - Recommendation

    @ObservationIgnored nonisolated(unsafe) private var _recommendation: WizardRecommendation?
    var recommendation: WizardRecommendation? {
        get { access(keyPath: \.recommendation); return _recommendation }
        set { withMutation(keyPath: \.recommendation) { _recommendation = newValue } }
    }

    // MARK: - Confirmation Details

    @ObservationIgnored nonisolated(unsafe) private var _showDetails = false
    var showDetails: Bool {
        get { access(keyPath: \.showDetails); return _showDetails }
        set { withMutation(keyPath: \.showDetails) { _showDetails = newValue } }
    }

    // MARK: - Completion

    @ObservationIgnored nonisolated(unsafe) private var _isComplete = false
    var isComplete: Bool {
        get { access(keyPath: \.isComplete); return _isComplete }
        set { withMutation(keyPath: \.isComplete) { _isComplete = newValue } }
    }

    // MARK: - Internal

    private var openRouterValidationTask: Task<Void, Never>?
    private var voyageValidationTask: Task<Void, Never>?
    private var assemblyAIValidationTask: Task<Void, Never>?
    private var elevenLabsValidationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Initialize from the detection snapshot after `SetupDetector.detect()`.
    func configure(
        with snapshot: SetupSnapshot,
        currentSettings: SettingsStore? = nil,
        isReconfiguration: Bool = false
    ) {
        self.snapshot = snapshot
        self.isDetecting = false
        self.isReconfiguration = isReconfiguration
        self.micPermission = snapshot.micPermission

        if !snapshot.existingOpenRouterKey.isEmpty {
            openRouterKeyInput = snapshot.existingOpenRouterKey
        }
        if !snapshot.existingVoyageKey.isEmpty {
            voyageKeyInput = snapshot.existingVoyageKey
        }
        if !snapshot.existingAssemblyAIKey.isEmpty {
            assemblyAIKeyInput = snapshot.existingAssemblyAIKey
        }
        if !snapshot.existingElevenLabsKey.isEmpty {
            elevenLabsKeyInput = snapshot.existingElevenLabsKey
        }

        if isReconfiguration, let currentSettings {
            seedFromCurrentSettings(currentSettings)
        }
    }

    // MARK: - Navigation

    /// Whether the user can advance from the current step.
    var canAdvance: Bool {
        switch currentStep {
        case .intent:
            return intent != nil && !isDetecting

        case .languagePrivacy:
            if intent == .transcribe {
                return language != nil
            }
            return language != nil && privacy != nil

        case .providerSetup:
            guard let recommendation else { return false }
            if recommendation.profile.isCloud {
                let openRouterValid = openRouterValidation == .valid || openRouterValidation?.isNetworkError == true
                let voyageValid = voyageKeyInput.isEmpty || voyageValidation == .valid || voyageValidation?.isNetworkError == true
                let asrKeyValid = cloudASRKeyValidation == .valid || cloudASRKeyValidation?.isNetworkError == true
                return !openRouterKeyInput.isEmpty
                    && openRouterValid
                    && voyageValid
                    && !cloudASRKeyInput.isEmpty
                    && asrKeyValid
            }
            if recommendation.profile.isLocal {
                return ollamaStatus == .readyWithModels
            }
            return true

        case .confirmation:
            return micPermission == .authorized
        }
    }

    /// Move forward to the next step in the wizard.
    func advance() {
        guard canAdvance else { return }

        let nextStep: WizardStep
        switch currentStep {
        case .intent:
            guard let intent else { return }
            nextStep = RecommendationEngine.nextStepAfterIntent(intent: intent, snapshot: snapshot)

        case .languagePrivacy:
            guard let intent else { return }
            let resolvedPrivacy = privacy ?? inferredPrivacy(for: intent)
            nextStep = RecommendationEngine.nextStepAfterLanguagePrivacy(intent: intent, privacy: resolvedPrivacy)

        case .providerSetup:
            nextStep = .confirmation

        case .confirmation:
            return
        }

        recomputeIfNeeded()
        stepHistory.append(nextStep)
        currentStep = nextStep
    }

    /// Navigate back to the previous step in the user's actual path.
    func goBack() {
        guard stepHistory.count > 1 else { return }
        stepHistory.removeLast()
        currentStep = stepHistory.last ?? .intent
    }

    /// Whether the current step should show a back button.
    var hasBackButton: Bool {
        stepHistory.count > 1
    }

    // MARK: - Recommendation Engine

    private func recomputeIfNeeded() {
        guard let intent else {
            recommendation = nil
            return
        }

        let resolvedLanguage = language ?? inferredLanguage()
        let resolvedPrivacy = intent == .transcribe ? .cloud : inferredPrivacy(for: intent)

        recommendation = RecommendationEngine.recommend(
            intent: intent,
            language: resolvedLanguage,
            privacy: resolvedPrivacy,
            snapshot: snapshot
        )
    }

    private func inferredLanguage() -> WizardLanguage {
        snapshot.isEnglishLocale ? .english : .multilingual
    }

    private func inferredPrivacy(for intent: WizardIntent) -> WizardPrivacy {
        guard intent != .transcribe else {
            return .cloud
        }

        if let privacy {
            return privacy
        }
        if snapshot.ollamaReachable && !snapshot.hasOpenRouterKey {
            return .local
        }
        return .cloud
    }

    var requiredCloudASRProviderName: String? {
        switch recommendation?.transcriptionModel {
        case .assemblyAI?:
            return "AssemblyAI"
        case .elevenLabsScribe?:
            return "ElevenLabs"
        default:
            return nil
        }
    }

    private var cloudASRKeyInput: String {
        switch recommendation?.transcriptionModel {
        case .assemblyAI?:
            return assemblyAIKeyInput
        case .elevenLabsScribe?:
            return elevenLabsKeyInput
        default:
            return ""
        }
    }

    private var cloudASRKeyValidation: APIKeyValidator.ValidationResult? {
        switch recommendation?.transcriptionModel {
        case .assemblyAI?:
            return assemblyAIValidation
        case .elevenLabsScribe?:
            return elevenLabsValidation
        default:
            return nil
        }
    }

    // MARK: - API Key Validation

    private func validateOpenRouterKey() {
        openRouterValidationTask?.cancel()
        isValidatingOpenRouter = true
        openRouterValidation = nil

        openRouterValidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            let result = await APIKeyValidator.validateOpenRouterKey(self.openRouterKeyInput)
            guard !Task.isCancelled else { return }

            self.openRouterValidation = result
            self.isValidatingOpenRouter = false
        }
    }

    private func validateVoyageKey() {
        voyageValidationTask?.cancel()
        isValidatingVoyage = true
        voyageValidation = nil

        voyageValidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            let result = await APIKeyValidator.validateVoyageKey(self.voyageKeyInput)
            guard !Task.isCancelled else { return }

            self.voyageValidation = result
            self.isValidatingVoyage = false
        }
    }

    private func validateAssemblyAIKey() {
        assemblyAIValidationTask?.cancel()
        isValidatingAssemblyAI = true
        assemblyAIValidation = nil

        assemblyAIValidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            let result = await APIKeyValidator.validateAssemblyAIKey(self.assemblyAIKeyInput)
            guard !Task.isCancelled else { return }

            self.assemblyAIValidation = result
            self.isValidatingAssemblyAI = false
        }
    }

    private func validateElevenLabsKey() {
        elevenLabsValidationTask?.cancel()
        isValidatingElevenLabs = true
        elevenLabsValidation = nil

        elevenLabsValidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            let result = await APIKeyValidator.validateElevenLabsKey(self.elevenLabsKeyInput)
            guard !Task.isCancelled else { return }

            self.elevenLabsValidation = result
            self.isValidatingElevenLabs = false
        }
    }

    // MARK: - Ollama Actions

    func checkOllamaStatus() async {
        guard let recommendation else { return }
        ollamaStatus = await OllamaSetupClient.checkStatus(requiredModels: recommendation.requiredOllamaModels)
    }

    func pullMissingModels() async {
        guard case .missingModels(let missing) = ollamaStatus else { return }

        isPullingModel = true
        ollamaPullError = nil
        ollamaPullProgress = 0

        for model in missing {
            do {
                try await OllamaSetupClient.pullModel(model) { [weak self] progress in
                    Task { @MainActor in
                        self?.ollamaPullProgress = progress.fraction
                    }
                }
            } catch {
                ollamaPullError = "Couldn't download the model. Check your internet connection and try again."
                isPullingModel = false
                return
            }
        }

        isPullingModel = false
        ollamaPullProgress = nil
        await checkOllamaStatus()
    }

    // MARK: - Mic Permission

    func requestMicPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micPermission = granted ? .authorized : .denied
    }

    func recheckMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermission = .authorized
        case .notDetermined:
            micPermission = .notDetermined
        case .denied:
            micPermission = .denied
        case .restricted:
            micPermission = .restricted
        @unknown default:
            micPermission = .denied
        }
    }

    // MARK: - Apply Settings

    /// Write the resolved recommendation into `SettingsStore` in one batch.
    func applySettings(to settings: SettingsStore) {
        guard let recommendation else { return }

        clearStaleSettings(for: recommendation.profile, in: settings)

        settings.transcriptionModel = recommendation.transcriptionModel
        settings.transcriptionLocale = recommendation.transcriptionLocale

        if let provider = recommendation.llmProvider {
            settings.llmProvider = provider
        }
        if let selectedModel = recommendation.selectedModel {
            settings.selectedModel = selectedModel
        }
        if let realtimeModel = recommendation.realtimeModel {
            settings.realtimeModel = realtimeModel
        }
        if let ollamaBaseURL = recommendation.ollamaBaseURL {
            settings.ollamaBaseURL = ollamaBaseURL
        }
        if let ollamaLLMModel = recommendation.ollamaLLMModel {
            settings.ollamaLLMModel = ollamaLLMModel
        }
        if let ollamaEmbedModel = recommendation.ollamaEmbedModel {
            settings.ollamaEmbedModel = ollamaEmbedModel
        }

        if let embeddingProvider = recommendation.embeddingProvider {
            settings.embeddingProvider = embeddingProvider
        } else {
            settings.embeddingProvider = recommendation.profile.isLocal ? .ollama : .voyageAI
        }
        settings.suggestionPanelEnabled = recommendation.suggestionPanelEnabled

        if recommendation.profile.needsOpenRouterKey {
            settings.openRouterApiKey = openRouterKeyInput
        }
        if intent == .fullCopilot, recommendation.profile.isCloud {
            settings.voyageApiKey = voyageKeyInput
        }
        switch recommendation.transcriptionModel {
        case .assemblyAI:
            settings.assemblyAIApiKey = assemblyAIKeyInput
            settings.elevenLabsApiKey = ""
        case .elevenLabsScribe:
            settings.elevenLabsApiKey = elevenLabsKeyInput
            settings.assemblyAIApiKey = ""
        default:
            break
        }

        settings.suggestionVerbosity = recommendation.suggestionVerbosity
        settings.sidebarMode = recommendation.sidebarMode
        settings.sidecastIntensity = recommendation.sidecastIntensity
        settings.meetingAutoDetectEnabled = true
        settings.hasShownAutoDetectExplanation = true

        isComplete = true
    }

    /// Clear settings that belonged to a previous profile but not the new one.
    private func clearStaleSettings(for profile: WizardProfile, in settings: SettingsStore) {
        if !profile.isCloud {
            settings.openRouterApiKey = ""
            settings.openAIApiKey = ""
            settings.anthropicApiKey = ""
            settings.voyageApiKey = ""
            settings.selectedModel = "google/gemini-3-flash-preview"
            settings.realtimeModel = "google/gemini-3.1-flash-lite-preview"
            settings.openAIModel = "gpt-4.1-mini"
            settings.anthropicModel = "claude-sonnet-4-5-20250929"
        }

        if !profile.isCloud {
            settings.assemblyAIApiKey = ""
            settings.elevenLabsApiKey = ""
        }

        if !profile.isLocal {
            settings.ollamaBaseURL = "http://localhost:11434"
            settings.ollamaLLMModel = "qwen3:8b"
            settings.ollamaEmbedModel = "nomic-embed-text"
        }

        if profile.isTranscriptOnly || intent != .fullCopilot {
            settings.suggestionPanelEnabled = false
        }
    }

    private func seedFromCurrentSettings(_ settings: SettingsStore) {
        let hasConfiguredLLM: Bool
        switch settings.llmProvider {
        case .openRouter:
            hasConfiguredLLM = !settings.openRouterApiKey.isEmpty
        case .openAI:
            hasConfiguredLLM = !settings.openAIApiKey.isEmpty
        case .anthropic:
            hasConfiguredLLM = !settings.anthropicApiKey.isEmpty
        case .ollama, .lmStudio, .mlx, .openAICompatible:
            hasConfiguredLLM = true
        }

        intent = hasConfiguredLLM
            ? (settings.suggestionPanelEnabled ? .fullCopilot : .notes)
            : .transcribe

        if settings.transcriptionModel == .parakeetV2,
           settings.transcriptionLocale.lowercased().hasPrefix("en") {
            language = .english
        } else {
            language = .multilingual
        }

        switch settings.llmProvider {
        case .ollama, .lmStudio:
            privacy = .local
        case .openRouter, .openAI, .anthropic, .mlx, .openAICompatible:
            privacy = .cloud
        }
    }
}

// MARK: - Helpers

extension APIKeyValidator.ValidationResult {
    var isNetworkError: Bool {
        if case .networkError = self {
            return true
        }
        return false
    }
}
