import AppKit
import Foundation
import Observation

struct WhatsNewRelease: Identifiable, Equatable {
    var id: String { version }

    let version: String
    let title: String
    let body: String
    let htmlURL: URL
}

enum WhatsNewReleaseClient {
    enum ClientError: Error {
        case invalidURL
        case invalidResponse
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }

    static func fetch(version: String) async throws -> WhatsNewRelease {
        guard let url = URL(string: "https://api.github.com/repos/yazinsai/OpenOats/releases/tags/v\(version)") else {
            throw ClientError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return WhatsNewRelease(
            version: normalizedTag(release.tagName) ?? version,
            title: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? release.name!
                : "OpenOats \(version)",
            body: release.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? release.body!
                : "No release notes were published for this version.",
            htmlURL: release.htmlURL
        )
    }

    private static func normalizedTag(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v") else { return trimmed.isEmpty ? nil : trimmed }
        let version = String(trimmed.dropFirst())
        return version.isEmpty ? nil : version
    }
}

@Observable
@MainActor
final class WhatsNewController {
    static let lastSeenVersionKey = "lastSeenReleaseNotesVersion"

    private let defaults: UserDefaults
    private let currentVersionProvider: () -> String?
    private let fetchRelease: (String) async throws -> WhatsNewRelease
    private var checkedThisLaunch = false

    var presentedRelease: WhatsNewRelease?

    init(
        defaults: UserDefaults = .standard,
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        },
        fetchRelease: @escaping (String) async throws -> WhatsNewRelease = WhatsNewReleaseClient.fetch(version:)
    ) {
        self.defaults = defaults
        self.currentVersionProvider = currentVersionProvider
        self.fetchRelease = fetchRelease
    }

    func presentPostUpdateReleaseNotesIfNeeded() async {
        guard !checkedThisLaunch else { return }
        checkedThisLaunch = true

        guard let currentVersion = normalizedVersion(currentVersionProvider()) else { return }
        guard let lastSeenVersion = defaults.string(forKey: Self.lastSeenVersionKey) else {
            defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
            return
        }
        guard Self.shouldShow(currentVersion: currentVersion, lastSeenVersion: lastSeenVersion) else { return }

        do {
            presentedRelease = try await fetchRelease(currentVersion)
        } catch {
            DiagnosticsSupport.record(
                category: "app",
                message: "Unable to load release notes for \(currentVersion): \(error.localizedDescription)"
            )
        }
    }

    func markPresentedReleaseSeen() {
        guard let release = presentedRelease else { return }
        defaults.set(release.version, forKey: Self.lastSeenVersionKey)
        presentedRelease = nil
    }

    static func shouldShow(currentVersion: String, lastSeenVersion: String) -> Bool {
        guard let current = SemanticVersion(currentVersion),
              let lastSeen = SemanticVersion(lastSeenVersion) else {
            return false
        }
        return current > lastSeen
    }

    private func normalizedVersion(_ version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawVersion: String) {
        let normalized = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
