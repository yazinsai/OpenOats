import FluidAudio
import Foundation

enum OpenOatsLocalModelStore {
    static func parakeetDirectory(
        for version: AsrModelVersion,
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) -> URL {
        let wrapper = baseDirectory
            .appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent(stableName(for: version), isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)

        _ = migrateParakeetIfNeeded(
            version: version,
            wrapperDirectory: wrapper,
            fluidAudioModelsRoot: fluidAudioModelsRoot
        )
        return wrapper
    }

    static func qwen3Directory(
        variant: Qwen3AsrVariant = .f32,
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) -> URL {
        let target = baseDirectory
            .appendingPathComponent("qwen3-asr", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)

        _ = migrateQwen3IfNeeded(
            variant: variant,
            targetDirectory: target,
            fluidAudioModelsRoot: fluidAudioModelsRoot
        )
        return target
    }

    static func clearParakeetCache(
        for version: AsrModelVersion,
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) {
        let fileManager = FileManager.default
        let wrapper = baseDirectory
            .appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent(stableName(for: version), isDirectory: true)
        try? fileManager.removeItem(at: wrapper)
        parakeetMigrationCandidates(for: version, fluidAudioModelsRoot: fluidAudioModelsRoot).forEach {
            try? fileManager.removeItem(at: $0)
        }
    }

    static func clearQwen3Cache(
        variant: Qwen3AsrVariant = .f32,
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) {
        let fileManager = FileManager.default
        let target = baseDirectory
            .appendingPathComponent("qwen3-asr", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
        try? fileManager.removeItem(at: target)
        qwen3MigrationCandidates(for: variant, fluidAudioModelsRoot: fluidAudioModelsRoot).forEach {
            try? fileManager.removeItem(at: $0)
        }
    }

    static func migrateDownloadedQwen3Models(
        from sourceDirectory: URL,
        variant: Qwen3AsrVariant = .f32,
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) -> URL {
        let target = baseDirectory
            .appendingPathComponent("qwen3-asr", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)

        moveDirectoryIfNeeded(from: sourceDirectory, to: target)
        _ = migrateQwen3IfNeeded(
            variant: variant,
            targetDirectory: target,
            fluidAudioModelsRoot: fluidAudioModelsRoot
        )
        return target
    }

    static func defaultBaseDirectory(appSupportDirectory: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let appSupport =
            appSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Transcription", isDirectory: true)
    }

    private static func migrateParakeetIfNeeded(
        version: AsrModelVersion,
        wrapperDirectory: URL,
        fluidAudioModelsRoot: URL
    ) -> URL {
        let fileManager = FileManager.default
        let targetDirectory = parakeetRepoDirectory(for: version, wrapperDirectory: wrapperDirectory)
        if fileManager.fileExists(atPath: targetDirectory.path) {
            return wrapperDirectory
        }

        for candidate in parakeetMigrationCandidates(for: version, fluidAudioModelsRoot: fluidAudioModelsRoot) {
            if fileManager.fileExists(atPath: candidate.path) {
                moveDirectoryIfNeeded(from: candidate, to: targetDirectory)
                break
            }
        }

        return wrapperDirectory
    }

    private static func migrateQwen3IfNeeded(
        variant: Qwen3AsrVariant,
        targetDirectory: URL,
        fluidAudioModelsRoot: URL
    ) -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetDirectory.path) {
            return targetDirectory
        }

        for candidate in qwen3MigrationCandidates(for: variant, fluidAudioModelsRoot: fluidAudioModelsRoot) {
            if fileManager.fileExists(atPath: candidate.path) {
                moveDirectoryIfNeeded(from: candidate, to: targetDirectory)
                break
            }
        }

        return targetDirectory
    }

    private static func parakeetMigrationCandidates(
        for version: AsrModelVersion,
        fluidAudioModelsRoot: URL
    ) -> [URL] {
        candidateDirectories(
            currentRelativePath: parakeetCurrentRelativePath(for: version),
            legacyRelativePath: parakeetLegacyRelativePath(for: version),
            root: fluidAudioModelsRoot
        )
    }

    private static func qwen3MigrationCandidates(
        for variant: Qwen3AsrVariant,
        fluidAudioModelsRoot: URL
    ) -> [URL] {
        candidateDirectories(
            currentRelativePath: variant.repo.folderName,
            legacyRelativePath: variant.repo.name,
            root: fluidAudioModelsRoot
        )
    }

    private static func candidateDirectories(
        currentRelativePath: String,
        legacyRelativePath: String,
        root: URL
    ) -> [URL] {
        var seen: Set<String> = []
        return [currentRelativePath, legacyRelativePath]
            .map { append(relativePath: $0, to: root) }
            .filter { url in
                let key = url.standardizedFileURL.path
                return seen.insert(key).inserted
            }
    }

    private static func parakeetRepoDirectory(for version: AsrModelVersion, wrapperDirectory: URL) -> URL {
        wrapperDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(parakeetCurrentRelativePath(for: version), isDirectory: true)
    }

    private static func moveDirectoryIfNeeded(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.removeItem(at: source)
            } catch {
                return
            }
        }
    }

    private static func parakeetCurrentRelativePath(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return Repo.parakeetV2.folderName
        case .v3:
            return Repo.parakeet.folderName
        case .tdtCtc110m:
            return Repo.parakeetTdtCtc110m.folderName
        case .ctcZhCn:
            return Repo.parakeetCtcZhCn.folderName
        }
    }

    private static func parakeetLegacyRelativePath(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return Repo.parakeetV2.name
        case .v3:
            return Repo.parakeet.name
        case .tdtCtc110m:
            return Repo.parakeetTdtCtc110m.name
        case .ctcZhCn:
            return Repo.parakeetCtcZhCn.name
        }
    }

    private static func append(relativePath: String, to base: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private static func stableName(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return "parakeet-v2"
        case .v3:
            return "parakeet-v3"
        case .tdtCtc110m:
            return "parakeet-tdt-ctc-110m"
        case .ctcZhCn:
            return "parakeet-ctc-zh-cn"
        }
    }
}
