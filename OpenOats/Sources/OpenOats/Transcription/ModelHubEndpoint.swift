import Foundation
import FluidAudio

/// The single Hugging Face Hub-compatible endpoint used for every local model
/// download OpenOats manages (WhisperKit, swift-transformers tokenizers, and all
/// FluidAudio models). Resolved once at launch; changing it requires a restart.
enum ModelHubEndpoint {
    static let defaultEndpoint = "https://huggingface.co"

    enum Source: String {
        case setting = "OpenOats setting"
        case hfEndpoint = "HF_ENDPOINT"
        case registryURL = "REGISTRY_URL"
        case modelRegistryURL = "MODEL_REGISTRY_URL"
        case defaultEndpoint = "default"
    }

    /// Endpoint applied at launch. Read by downloaders that take an explicit endpoint.
    nonisolated(unsafe) private(set) static var current = defaultEndpoint

    /// First non-blank value in precedence order: setting, HF_ENDPOINT, REGISTRY_URL,
    /// MODEL_REGISTRY_URL, then the official Hub. An invalid value is still returned
    /// (never silently replaced by huggingface.co) so downloads fail against it.
    static func resolve(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (endpoint: String, source: Source) {
        let candidates: [(String?, Source)] = [
            (configured, .setting),
            (environment["HF_ENDPOINT"], .hfEndpoint),
            (environment["REGISTRY_URL"], .registryURL),
            (environment["MODEL_REGISTRY_URL"], .modelRegistryURL),
        ]
        for (value, source) in candidates {
            var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            if !trimmed.isEmpty { return (trimmed, source) }
        }
        return (defaultEndpoint, .defaultEndpoint)
    }

    /// Returns a user-facing problem with a non-blank endpoint, or nil when it is usable.
    static func validationError(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return "Enter an absolute http(s) URL, e.g. https://hf-mirror.example.com"
        }
        if components.user != nil || components.password != nil {
            return "Remove credentials from the URL."
        }
        if components.query != nil || components.fragment != nil {
            return "Remove the query string or fragment from the URL."
        }
        return nil
    }

    /// Points every model library at the resolved endpoint. Call once at launch,
    /// before any model manager is created.
    static func apply(configured: String?) {
        let endpoint = resolve(configured: configured).endpoint
        current = endpoint
        ModelRegistry.baseURL = endpoint
        // swift-transformers' HubApi (used for Whisper tokenizers) reads HF_ENDPOINT
        // when no endpoint is passed explicitly.
        setenv("HF_ENDPOINT", endpoint, 1)
    }
}
