import XCTest
@testable import OpenOatsKit

@MainActor
final class KnowledgeBaseFoldersTests: XCTestCase {
    private func withServer(name: String = #function, _ test: (AppSettings, URL, URL) async throws -> Void) async throws {
        let proofRoot = ProcessInfo.processInfo.environment["OPENOATS_KB_PROOF_DIR"]
        let directory = proofRoot.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "com.openoats.folders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test_kb_embeddings.py")
        process.arguments = [script.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
            defaults.removePersistentDomain(forName: suiteName)
            if proofRoot == nil { try? FileManager.default.removeItem(at: directory) }
        }
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let settings = AppSettings(storage: AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: directory.appendingPathComponent("notes"),
            runMigrations: false
        ))
        settings.embeddingProvider = .openAICompatible
        settings.openAIEmbedBaseURL = "http://127.0.0.1:\(port)"
        settings.openAIEmbedModel = "test"
        try await test(settings, directory, directory.appendingPathComponent("kb-cache.json"))
    }

    private func folder(_ path: String, in directory: URL, text: String, filename: String = "reference.md") throws -> URL {
        let folder = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        return folder
    }

    func testIndexesSearchesAndRestoresMultipleSourcesWithoutFilenameCollisions() async throws {
        try await withServer { settings, directory, cache in
            let apple = try self.folder("work/references", in: directory, text: "# Apple\napple planning")
            let banana = try self.folder("personal/references", in: directory, text: "# Banana\nbanana research")
            settings.kbFolderPaths = [apple.path, banana.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 2)
            XCTAssertEqual(kb.chunks.count, 2)
            XCTAssertEqual(Set(kb.chunks.map(\.sourceFile)), ["work/references :: reference.md", "personal/references :: reference.md"])
            let apples = await kb.search(query: "apple", topK: 1)
            XCTAssertEqual(apples.first?.sourceFile, "work/references :: reference.md")
            let bananas = await kb.searchContextPacks(queries: ["banana"], topK: 1)
            XCTAssertEqual(bananas.first?.relativePath, "personal/references :: reference.md")
            XCTAssertNil(bananas.first?.previousSiblingText)
            XCTAssertNil(bananas.first?.nextSiblingText)
            let restored = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let didRestore = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertTrue(didRestore)
            XCTAssertEqual(restored.fileCount, 2)
            let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            XCTAssertEqual(log.split(separator: "\n").count, 3)
            let proof: [String: Any] = [
                "endpoint": settings.openAIEmbedBaseURL,
                "fileCount": kb.fileCount,
                "chunkCount": kb.chunks.count,
                "sources": kb.chunks.map(\.sourceFile),
                "appleSearchSource": apples.first?.sourceFile ?? "",
                "bananaContextSource": bananas.first?.relativePath ?? "",
                "restored": didRestore,
                "restoredFileCount": restored.fileCount,
                "httpRequests": log.split(separator: "\n").count,
                "externalInference": false
            ]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("proof.json"))
        }
    }

    func testRootLabelBoundariesKeepNestedDocumentCitationsAndSiblingsSeparate() async throws {
        try await withServer { settings, directory, cache in
            let first = try self.folder("kb/team-a/reference", in: directory, text: "apple facts", filename: "plan.md")
            let second = try self.folder("kb/team-b/reference", in: directory, text: "papaya facts", filename: "plan.md")
            let third = try self.folder("archive/team-a/reference", in: directory, text: "banana facts", filename: "plan.md")
                .deletingLastPathComponent()
            settings.kbFolderPaths = [first.path, second.path, third.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 3)
            XCTAssertEqual(Set(kb.chunks.map(\.documentID)).count, 3)
            XCTAssertEqual(Set(kb.chunks.map(\.sourceFile)), [
                "team-a/reference :: plan.md",
                "team-b/reference :: plan.md",
                "team-a :: reference/plan.md"
            ])
            for (query, source) in [
                ("apple", "team-a/reference :: plan.md"),
                ("banana", "team-a :: reference/plan.md")
            ] {
                let packs = await kb.searchContextPacks(queries: [query], topK: 1)
                XCTAssertEqual(packs.first?.relativePath, source)
                XCTAssertNil(packs.first?.previousSiblingText)
                XCTAssertNil(packs.first?.nextSiblingText)
            }
            let restored = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let didRestore = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertTrue(didRestore)
            XCTAssertEqual(Set(restored.chunks.map(\.documentID)).count, 3)
            var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            oldCache.removeValue(forKey: "formatVersion")
            try JSONSerialization.data(withJSONObject: oldCache).write(to: cache)
            let restoredOldCache = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertFalse(restoredOldCache)
        }
    }

    func testRootNamesContainingCitationSeparatorStayDistinct() async throws {
        try await withServer { settings, directory, cache in
            let first = try self.folder("alpha :: beta", in: directory, text: "apple facts", filename: "plan.md")
            let second = try self.folder("alpha", in: directory, text: "banana facts", filename: "beta :: plan.md")
            settings.kbFolderPaths = [first.path, second.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(Set(kb.chunks.map(\.sourceFile)), [
                "alpha %3A%3A beta :: plan.md",
                "alpha :: beta :: plan.md"
            ])
        }
    }

    func testIdenticalFilesAndOverlappingRootsIndexEachPhysicalFileOnce() async throws {
        try await withServer { settings, directory, cache in
            let first = try self.folder("one", in: directory, text: "apple identical text")
            let second = try self.folder("two", in: directory, text: "apple identical text")
            settings.kbFolderPaths = [directory.path, first.path, second.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 2)
            XCTAssertEqual(kb.chunks.count, 2)
            XCTAssertEqual(Set(kb.chunks.map(\.sourceFile)).count, 2)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 2)
            XCTAssertEqual(kb.chunks.count, 2)
        }
    }

    func testRemovalEmptyFoldersAndDeletedFilesCannotRestoreStaleResults() async throws {
        try await withServer { settings, directory, cache in
            let apple = try self.folder("apple", in: directory, text: "apple facts")
            let banana = try self.folder("banana", in: directory, text: "banana facts")
            settings.kbFolderPaths = [apple.path, banana.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            settings.kbFolderPaths = [banana.path]
            let removed = await kb.search(query: "apple")
            XCTAssertTrue(removed.isEmpty)
            XCTAssertEqual(kb.chunks.count, 1)
            try FileManager.default.removeItem(at: banana.appendingPathComponent("reference.md"))
            let restored = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let didRestore = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertTrue(didRestore)
            XCTAssertTrue(restored.chunks.isEmpty)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 0)
            XCTAssertTrue(kb.chunks.isEmpty)
            settings.kbFolderPaths = []
            let empty = await kb.search(query: "banana")
            XCTAssertTrue(empty.isEmpty)
            XCTAssertTrue(kb.chunks.isEmpty)
        }
    }

    func testRemovedSourcesCannotReturnFromConcurrentIndexing() async throws {
        try await withServer { settings, directory, cache in
            let apple = try self.folder("apple", in: directory, text: "apple facts")
            let banana = try self.folder("banana", in: directory, text: "banana facts")
            settings.kbFolderPaths = [apple.path]
            settings.openAIEmbedModel = "slow-test"
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let first = Task { await kb.index(folderURLs: [apple]) }
            let log = directory.appendingPathComponent("requests.jsonl")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: log.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
            settings.kbFolderPaths = [banana.path]
            settings.openAIEmbedModel = "test"
            await kb.index(folderURLs: settings.kbFolderURLs)
            await first.value
            XCTAssertEqual(kb.chunks.map(\.text), ["banana facts"])
            let restored = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let didRestore = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertTrue(didRestore)
            XCTAssertEqual(restored.chunks.map(\.text), ["banana facts"])
        }
    }
    func testClearingAllSourcesRejectsInFlightIndexAndSearchResults() async throws {
        try await withServer { settings, directory, cache in
            let apple = try self.folder("apple", in: directory, text: "apple facts")
            settings.kbFolderPaths = [apple.path]
            settings.openAIEmbedModel = "slow-test"
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let indexing = Task { await kb.index(folderURLs: [apple]) }
            let log = directory.appendingPathComponent("requests.jsonl")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: log.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
            settings.kbFolderPaths = []
            kb.clear()
            await indexing.value
            XCTAssertTrue(kb.chunks.isEmpty)
            XCTAssertFalse(kb.isIndexed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    func testCacheRejectsChangedContentsAndReindexesEmptyDocuments() async throws {
        try await withServer { settings, directory, cache in
            let root = try self.folder("references", in: directory, text: "apple facts")
            settings.kbFolderPaths = [root.path]
            let kb = KnowledgeBase(settings: settings, cacheFileURL: cache)
            await kb.index(folderURLs: settings.kbFolderURLs)
            try "banana facts".write(to: root.appendingPathComponent("reference.md"), atomically: true, encoding: .utf8)
            let restored = KnowledgeBase(settings: settings, cacheFileURL: cache)
            let didRestore = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertFalse(didRestore)
            XCTAssertTrue(restored.chunks.isEmpty)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.chunks.map(\.text), ["banana facts"])
            try "".write(to: root.appendingPathComponent("reference.md"), atomically: true, encoding: .utf8)
            await kb.index(folderURLs: settings.kbFolderURLs)
            XCTAssertEqual(kb.fileCount, 1)
            XCTAssertTrue(kb.chunks.isEmpty)
            let didRestoreEmpty = await restored.loadCachedStateIfAvailable(folderURLs: settings.kbFolderURLs)
            XCTAssertTrue(didRestoreEmpty)
            XCTAssertTrue(restored.chunks.isEmpty)
        }
    }

}
