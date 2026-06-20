@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Actor that owns all auto-detection for the setup wizard.
/// Runs hardware checks instantly and network probes with a timeout.
actor SetupDetector {
    /// Dependency surface injected in tests.
    protocol Dependencies: Sendable {
        var physicalMemoryBytes: UInt64 { get }
        var preferredLocale: String { get }
        func availableInputDevices() -> [(id: AudioDeviceID, name: String)]
        func micAuthorizationStatus() -> MicPermissionStatus
        func modelStatuses() -> [TranscriptionModel: BackendStatus]
        func existingOpenRouterKey() async -> String
        func existingVoyageKey() async -> String
        func existingAssemblyAIKey() async -> String
        func existingElevenLabsKey() async -> String
        func fetchOllamaModels() async -> Result<[String], OllamaModelFetcher.FetchError>
    }

    /// Production dependencies that read real hardware, settings, and network state.
    struct LiveDependencies: Dependencies, Sendable {
        let settings: SettingsStore

        nonisolated var physicalMemoryBytes: UInt64 {
            ProcessInfo.processInfo.physicalMemory
        }

        nonisolated var preferredLocale: String {
            Locale.preferredLanguages.first ?? "en-US"
        }

        nonisolated func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
            MicCapture.availableInputDevices()
        }

        nonisolated func micAuthorizationStatus() -> MicPermissionStatus {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .denied
            }
        }

        nonisolated func modelStatuses() -> [TranscriptionModel: BackendStatus] {
            var result: [TranscriptionModel: BackendStatus] = [:]
            for model in TranscriptionModel.allCases {
                result[model] = model.makeBackend().checkStatus()
            }
            return result
        }

        func existingOpenRouterKey() async -> String {
            await MainActor.run { settings.openRouterApiKey }
        }

        func existingVoyageKey() async -> String {
            await MainActor.run { settings.voyageApiKey }
        }

        func existingAssemblyAIKey() async -> String {
            await MainActor.run { settings.assemblyAIApiKey }
        }

        func existingElevenLabsKey() async -> String {
            await MainActor.run { settings.elevenLabsApiKey }
        }

        nonisolated func fetchOllamaModels() async -> Result<[String], OllamaModelFetcher.FetchError> {
            await OllamaModelFetcher.fetchModels(baseURL: "http://localhost:11434")
        }
    }

    private let deps: any Dependencies

    init(dependencies: any Dependencies) {
        self.deps = dependencies
    }

    /// Run all detection and return an immutable snapshot.
    func detect() async -> SetupSnapshot {
        let ram = deps.physicalMemoryBytes
        let locale = deps.preferredLocale
        let audioDevices = deps.availableInputDevices()
        let micStatus = deps.micAuthorizationStatus()
        let modelStatuses = deps.modelStatuses()

        async let openRouterKey = deps.existingOpenRouterKey()
        async let voyageKey = deps.existingVoyageKey()
        async let assemblyAIKey = deps.existingAssemblyAIKey()
        async let elevenLabsKey = deps.existingElevenLabsKey()
        let ollamaResult = await withTimeoutResult(seconds: 3.0) {
            await self.deps.fetchOllamaModels()
        }

        let resolvedOpenRouterKey = await openRouterKey
        let resolvedVoyageKey = await voyageKey
        let resolvedAssemblyAIKey = await assemblyAIKey
        let resolvedElevenLabsKey = await elevenLabsKey

        return SetupSnapshot(
            physicalMemoryBytes: ram,
            systemLocale: locale,
            audioDevices: audioDevices,
            micPermission: micStatus,
            modelStatuses: modelStatuses,
            hasOpenRouterKey: !resolvedOpenRouterKey.isEmpty,
            hasVoyageKey: !resolvedVoyageKey.isEmpty,
            hasAssemblyAIKey: !resolvedAssemblyAIKey.isEmpty,
            hasElevenLabsKey: !resolvedElevenLabsKey.isEmpty,
            existingOpenRouterKey: resolvedOpenRouterKey,
            existingVoyageKey: resolvedVoyageKey,
            existingAssemblyAIKey: resolvedAssemblyAIKey,
            existingElevenLabsKey: resolvedElevenLabsKey,
            ollamaResult: ollamaResult
        )
    }

    private func withTimeoutResult(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async -> Result<[String], OllamaModelFetcher.FetchError>
    ) async -> Result<[String], OllamaModelFetcher.FetchError> {
        await withTaskGroup(of: Result<[String], OllamaModelFetcher.FetchError>.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .failure(.networkError("Ollama probe timed out after \(Int(seconds))s"))
            }

            let result = await group.next() ?? .failure(.networkError("Ollama probe cancelled"))
            group.cancelAll()
            return result
        }
    }
}
