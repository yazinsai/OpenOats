import Accelerate
import Foundation
import CryptoKit

/// A chunk of text from a knowledge base document.
struct KBChunk: Codable, Sendable {
    let text: String
    let sourceFile: String
    let documentID: String
    let headerContext: String
    let embedding: [Float]
    let relativePath: String     // e.g. "sales/pricing.md"
    let folderBreadcrumb: String // e.g. "sales"
    let documentTitle: String    // first H1 or filename sans extension

    init(text: String, sourceFile: String, headerContext: String, embedding: [Float], relativePath: String = "", folderBreadcrumb: String = "", documentTitle: String = "", documentID: String = "") {
        self.text = text
        self.sourceFile = sourceFile
        self.documentID = documentID.isEmpty ? sourceFile : documentID
        self.headerContext = headerContext
        self.embedding = embedding
        self.relativePath = relativePath
        self.folderBreadcrumb = folderBreadcrumb
        self.documentTitle = documentTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sourceFile = try container.decode(String.self, forKey: .sourceFile)
        documentID = try container.decodeIfPresent(String.self, forKey: .documentID) ?? sourceFile
        headerContext = try container.decode(String.self, forKey: .headerContext)
        embedding = try container.decode([Float].self, forKey: .embedding)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? sourceFile
        folderBreadcrumb = try container.decodeIfPresent(String.self, forKey: .folderBreadcrumb) ?? ""
        documentTitle = try container.decodeIfPresent(String.self, forKey: .documentTitle) ?? sourceFile
    }
}

/// Disk cache format for embedded KB chunks.
private struct KBCache: Codable, Sendable {
    var formatVersion = 1
    var entries: [String: [KBChunk]]
    /// Fingerprint of the embedding config used to produce these vectors.
    var embeddingConfigFingerprint: String?
    var folderPaths: [String]?
}

enum KnowledgeBaseIndexingStatus: Equatable, Sendable {
    case idle
    case scanning
    case embedding(completed: Int, total: Int, activeRange: ClosedRange<Int>?)
    case completed(total: Int)
    case blocked(message: String)
    case failed(message: String)

    var isVisible: Bool {
        self != .idle
    }

    var needsFrequentPolling: Bool {
        switch self {
        case .scanning, .embedding, .completed:
            return true
        case .idle, .blocked, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle:
            return ""
        case .scanning:
            return "Preparing knowledge base..."
        case .embedding:
            return "Indexing knowledge base..."
        case .completed:
            return "Knowledge base ready"
        case .blocked:
            return "Knowledge base indexing paused"
        case .failed:
            return "Knowledge base indexing failed"
        }
    }

    var detailText: String? {
        switch self {
        case .scanning:
            return "Scanning files and checking cached chunks"
        case .embedding(let completed, let total, let activeRange):
            if completed == 0 {
                if let activeRange {
                    return "Processing chunks \(activeRange.lowerBound.formatted())-\(activeRange.upperBound.formatted()) of \(total.formatted())"
                }
                return "\(total.formatted()) chunks queued"
            }
            return "\(completed.formatted()) of \(total.formatted()) chunks"
        case .completed(let total):
            return "\(total.formatted()) chunks indexed"
        case .blocked(let message), .failed(let message):
            return message
        case .idle:
            return nil
        }
    }

    var progress: Double? {
        guard case .embedding(let completed, let total, _) = self, total > 0, completed > 0 else {
            return nil
        }

        return min(max(Double(completed) / Double(total), 0), 1)
    }

    var percentText: String? {
        guard case .embedding(let completed, let total, _) = self, total > 0 else {
            return nil
        }

        if completed <= 0 {
            return nil
        }

        let progress = Double(completed) / Double(total)
        if progress < 0.01 {
            return "<1%"
        }

        return "\(Int(progress * 100))%"
    }

    var helpText: String {
        switch self {
        case .idle:
            return ""
        case .scanning:
            return "OpenOats is scanning your Knowledge Base folders so it can prepare meeting context."
        case .embedding:
            return "OpenOats is indexing your Knowledge Base folders so it can surface relevant context during meetings."
        case .completed:
            return "OpenOats finished indexing your Knowledge Base folders and can use it during meetings."
        case .blocked(let message), .failed(let message):
            return message
        }
    }
}

/// Embedding-based knowledge base search using Voyage AI or Ollama.
@Observable
@MainActor
final class KnowledgeBase {
    @ObservationIgnored nonisolated(unsafe) private var _chunks: [KBChunk] = []
    private(set) var chunks: [KBChunk] {
        get { access(keyPath: \.chunks); return _chunks }
        set { withMutation(keyPath: \.chunks) { _chunks = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isIndexed = false
    private(set) var isIndexed: Bool {
        get { access(keyPath: \.isIndexed); return _isIndexed }
        set { withMutation(keyPath: \.isIndexed) { _isIndexed = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _fileCount = 0
    private(set) var fileCount: Int {
        get { access(keyPath: \.fileCount); return _fileCount }
        set { withMutation(keyPath: \.fileCount) { _fileCount = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _indexingStatus: KnowledgeBaseIndexingStatus = .idle
    private(set) var indexingStatus: KnowledgeBaseIndexingStatus {
        get { access(keyPath: \.indexingStatus); return _indexingStatus }
        set { withMutation(keyPath: \.indexingStatus) { _indexingStatus = newValue } }
    }

    private var indexGeneration = UUID()
    private var indexedFolderPaths: [String] = []
    private var indexedFingerprint: String?
    private let cacheFileURL: URL
    private let settings: AppSettings
    private let voyageClient = VoyageClient()
    private let ollamaEmbedClient = OllamaEmbedClient()

    private nonisolated static func cacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenOats")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kb_cache.json")
    }

    init(settings: AppSettings, cacheFileURL: URL? = nil) {
        self.settings = settings
        self.cacheFileURL = cacheFileURL ?? Self.cacheURL()
    }

    @discardableResult
    func loadCachedStateIfAvailable(folderURLs: [URL]) async -> Bool {
        let generation = indexGeneration
        let paths = Self.canonicalFolderPaths(folderURLs)
        let fingerprint = embeddingConfigFingerprint()
        let cache = loadCache()
        guard cache.embeddingConfigFingerprint == fingerprint,
              cache.folderPaths == paths else { return false }
        let scan = await Task.detached {
            Self.scanFiles(in: folderURLs, cache: cache)
        }.value
        guard indexGeneration == generation,
              paths == Self.canonicalFolderPaths(settings.kbFolderURLs),
              fingerprint == embeddingConfigFingerprint(),
              scan.filesToEmbed.isEmpty else { return false }
        clear()
        indexedFolderPaths = paths
        indexedFingerprint = fingerprint
        finishIndexing(chunks: scan.cachedChunks, fileCount: scan.fileCount)
        indexingStatus = .idle
        return true
    }

    func index(folderURLs: [URL]) async {
        clear()
        let generation = indexGeneration
        let fingerprint = embeddingConfigFingerprint()
        let paths = Self.canonicalFolderPaths(folderURLs)
        indexedFolderPaths = paths
        indexedFingerprint = fingerprint

        guard !paths.isEmpty else {
            finishIndexing(chunks: [], fileCount: 0)
            indexingStatus = .idle
            return
        }

        if settings.embeddingProvider == .voyageAI && settings.voyageApiKey.isEmpty {
            indexingStatus = .blocked(message: "Add a Voyage AI API key in Settings to index your knowledge base.")
            return
        }

        indexingStatus = .scanning
        var cache = loadCache()
        if cache.embeddingConfigFingerprint != fingerprint || cache.folderPaths != paths {
            cache = KBCache(entries: [:], embeddingConfigFingerprint: fingerprint, folderPaths: paths)
        }

        let cacheSnapshot = cache
        let scanResult = await Task.detached {
            Self.scanFiles(in: folderURLs, cache: cacheSnapshot)
        }.value
        guard isCurrentIndex(generation) else { return }

        var allChunks = scanResult.cachedChunks
        let filesToEmbed = scanResult.filesToEmbed

        // Embed new/changed files in batches
        if !filesToEmbed.isEmpty {
            let allTextsToEmbed = filesToEmbed.flatMap { entry in
                entry.chunks.compactMap { chunk -> String? in
                    let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    var prefix = entry.relativePath
                    if !chunk.header.isEmpty { prefix += " > \(chunk.header)" }
                    return "\(prefix)\n\(trimmed)"
                }
            }

            guard !allTextsToEmbed.isEmpty else {
                cache.entries = cache.entries.filter { scanResult.currentCacheKeys.contains($0.key) }
                for entry in filesToEmbed { cache.entries[entry.key] = [] }
                saveCache(cache)
                finishIndexing(chunks: allChunks, fileCount: scanResult.fileCount)
                return
            }

            indexingStatus = .embedding(completed: 0, total: allTextsToEmbed.count, activeRange: nil)

            let result = await embedInBatches(texts: allTextsToEmbed, generation: generation)
            guard isCurrentIndex(generation) else { return }
            let embeddings = result.embeddings

            if embeddings.allSatisfy({ $0 == nil }) {
                failIndexing(
                    message: result.error ?? "Embedding failed before any chunks were indexed.",
                    availableChunks: allChunks,
                    fileCount: scanResult.fileCount
                )
                return
            }

            var offset = 0
            var failedChunkCount = 0
            for entry in filesToEmbed {
                var fileChunks: [KBChunk] = []
                for chunk in entry.chunks {
                    let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let embedding = embeddings[offset] {
                        let kbChunk = KBChunk(
                            text: chunk.text,
                            sourceFile: entry.relativePath,
                            headerContext: chunk.header,
                            embedding: Self.normalizeEmbedding(embedding),
                            relativePath: entry.relativePath,
                            folderBreadcrumb: entry.folderBreadcrumb,
                            documentTitle: entry.documentTitle,
                            documentID: entry.documentID
                        )
                        fileChunks.append(kbChunk)
                    } else {
                        failedChunkCount += 1
                    }
                    offset += 1
                }
                if fileChunks.count == entry.chunks.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count {
                    cache.entries[entry.key] = fileChunks
                }
                allChunks.append(contentsOf: fileChunks)
            }

            if failedChunkCount > 0 {
                Log.knowledgeBase.warning("KB indexing: \(failedChunkCount) chunks failed to embed, continuing with partial results")
            }
        }
        let allRelevantKeys = Set(filesToEmbed.map(\.key)).union(scanResult.currentCacheKeys)
        cache.entries = cache.entries.filter { allRelevantKeys.contains($0.key) }
        saveCache(cache)

        finishIndexing(chunks: allChunks, fileCount: scanResult.fileCount)
    }

    // MARK: - Background File Scanning

    private struct FileScanResult: Sendable {
        let fileCount: Int
        let cachedChunks: [KBChunk]
        let filesToEmbed: [FileToEmbed]
        let currentCacheKeys: Set<String>
    }

    private struct FileToEmbed: Sendable {
        let key: String
        let documentID: String
        let chunks: [(text: String, header: String)]
        let relativePath: String
        let folderBreadcrumb: String
        let documentTitle: String
    }

    private nonisolated static func scanFiles(in folderURLs: [URL], cache: KBCache) -> FileScanResult {
        let roots = canonicalFolderPaths(folderURLs).map { URL(fileURLWithPath: $0) }
        let labels = roots.map { root in
            var depth = 1
            while roots.filter({ $0.pathComponents.suffix(depth) == root.pathComponents.suffix(depth) }).count > 1 {
                depth += 1
            }
            return root.pathComponents.suffix(depth).joined(separator: "/")
                .replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: ":", with: "%3A")
        }
        var seen = Set<String>()
        var fileURLs: [URL] = []
        var cachedChunks: [KBChunk] = []
        var filesToEmbed: [FileToEmbed] = []
        var currentCacheKeys = Set<String>()

        for (index, root) in roots.enumerated() {
            for file in collectFilesStatic(in: root).sorted(by: { $0.path < $1.path }) {
                let fileURL = file.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(fileURL.path).inserted,
                      let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                fileURLs.append(fileURL)
                let fileName = file.lastPathComponent
                let documentID = sha256Static(fileURL.path)
                let cacheKey = documentID + ":" + sha256Static(content)
                currentCacheKeys.insert(cacheKey)
                if let cached = cache.entries[cacheKey] {
                    cachedChunks.append(contentsOf: cached)
                    continue
                }
                let localPath = String(fileURL.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
                let relativePath = roots.count > 1 ? labels[index] + " :: " + localPath : localPath
                let localFolder = (localPath as NSString).deletingLastPathComponent
                let folderBreadcrumb = roots.count > 1
                    ? labels[index] + (localFolder.isEmpty ? "" : " :: " + localFolder)
                    : localFolder
                let title = extractDocumentTitleStatic(from: content) ?? file.deletingPathExtension().lastPathComponent
                filesToEmbed.append(FileToEmbed(
                    key: cacheKey,
                    documentID: documentID,
                    chunks: chunkMarkdownStatic(content, sourceFile: fileName),
                    relativePath: relativePath,
                    folderBreadcrumb: folderBreadcrumb,
                    documentTitle: title
                ))
            }
        }
        return FileScanResult(fileCount: fileURLs.count, cachedChunks: cachedChunks, filesToEmbed: filesToEmbed, currentCacheKeys: currentCacheKeys)
    }

    func search(query: String, topK: Int = 5) async -> [KBResult] {
        return await search(queries: [query], topK: topK)
    }

    /// Multi-query search with score fusion. Deduplicates by chunk index, uses max score.
    func search(queries: [String], topK: Int = 5) async -> [KBResult] {
        await searchRaw(queries: queries, topK: topK).map(\.result)
    }

    /// Search returning rich context packs with adjacent sibling text.
    func searchContextPacks(queries: [String], topK: Int = 3) async -> [KBContextPack] {
        let raw = await searchRaw(queries: queries, topK: topK)
        return raw.map { chunkIndex, result in
            let chunk = chunks[chunkIndex]
            let prevSibling: String? = chunkIndex > 0 && chunks[chunkIndex - 1].documentID == chunk.documentID
                ? chunks[chunkIndex - 1].text : nil
            let nextSibling: String? = chunkIndex < chunks.count - 1 && chunks[chunkIndex + 1].documentID == chunk.documentID
                ? chunks[chunkIndex + 1].text : nil
            return KBContextPack(
                matchedText: result.text,
                relativePath: chunk.relativePath,
                folderBreadcrumb: chunk.folderBreadcrumb,
                documentTitle: chunk.documentTitle,
                headerBreadcrumb: result.headerContext,
                score: result.score,
                previousSiblingText: prevSibling,
                nextSiblingText: nextSibling
            )
        }
    }

    /// Core search implementation. Returns chunk indices alongside results so callers
    /// don't need to re-scan the chunks array to locate matched entries.
    private func searchRaw(queries: [String], topK: Int) async -> [(chunkIndex: Int, result: KBResult)] {
        await ensureSearchReady()

        let provider = settings.embeddingProvider
        guard isIndexed, !chunks.isEmpty else { return [] }

        if provider == .voyageAI {
            guard !settings.voyageApiKey.isEmpty else { return [] }
        }

        let validQueries = queries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validQueries.isEmpty else { return [] }

        let generation = indexGeneration
        let queryEmbeddings: [[Float]]
        do {
            queryEmbeddings = try await embedTexts(validQueries, inputType: "query")
        } catch {
            Log.knowledgeBase.error("KB search embed error: \(error, privacy: .public)")
            return []
        }

        guard isCurrentIndex(generation) else { return [] }

        // Score fusion: for each chunk, take max cosine similarity across all queries.
        // Query is normalized once per query; chunk embeddings are pre-normalized at index time,
        // so cosine similarity reduces to a single vDSP dot product.
        var bestScores: [Int: Float] = [:]
        for queryEmb in queryEmbeddings {
            let normQuery = Self.normalizeEmbedding(queryEmb)
            for i in 0..<chunks.count {
                let sim = cosineSimilarity(normQuery, chunks[i].embedding)
                if sim > 0.1 {
                    bestScores[i] = max(bestScores[i] ?? 0, sim)
                }
            }
        }

        var scored = bestScores.map { (index: $0.key, score: $0.value) }
        scored.sort { $0.score > $1.score }
        let topCandidates = Array(scored.prefix(10))

        guard !topCandidates.isEmpty else { return [] }

        // Rerank with Voyage (only when using Voyage AI provider)
        if provider == .voyageAI {
            let candidateDocs = topCandidates.map { chunks[$0.index].text }
            do {
                let reranked = try await voyageClient.rerank(
                    apiKey: settings.voyageApiKey,
                    query: validQueries.joined(separator: " "),
                    documents: candidateDocs,
                    topN: topK
                )
                guard isCurrentIndex(generation) else { return [] }
                return reranked.map { result in
                    let chunkIndex = topCandidates[result.index].index
                    let chunk = chunks[chunkIndex]
                    return (chunkIndex, KBResult(
                        text: chunk.text,
                        sourceFile: chunk.sourceFile,
                        headerContext: chunk.headerContext,
                        score: result.score
                    ))
                }
            } catch {
                Log.knowledgeBase.error("KB rerank error (falling back to cosine): \(error, privacy: .public)")
            }
        }

        guard isCurrentIndex(generation) else { return [] }
        return topCandidates.prefix(topK).map { candidate in
            let chunk = chunks[candidate.index]
            return (candidate.index, KBResult(
                text: chunk.text,
                sourceFile: chunk.sourceFile,
                headerContext: chunk.headerContext,
                score: Double(candidate.score)
            ))
        }
    }

    func clear() {
        indexGeneration = UUID()
        indexedFolderPaths = []
        indexedFingerprint = nil
        chunks.removeAll()
        isIndexed = false
        fileCount = 0
        indexingStatus = .idle
    }

    // MARK: - File Collection

    private nonisolated static func collectFilesStatic(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if (ext == "md" || ext == "txt"),
               (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(fileURL)
            }
        }
        return urls
    }

    // MARK: - Markdown Chunking

    /// Extracts the first H1 heading from markdown content, or nil.
    private nonisolated static func extractDocumentTitleStatic(from content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Splits markdown content into chunks aware of header hierarchy.
    private nonisolated static func chunkMarkdownStatic(_ text: String, sourceFile: String) -> [(text: String, header: String)] {
        let lines = text.components(separatedBy: .newlines)

        struct Section {
            var headers: [String] // hierarchy stack
            var lines: [String]
        }

        var sections: [Section] = []
        var current = Section(headers: [], lines: [])

        for line in lines {
            if line.hasPrefix("#") {
                // Flush current section
                if !current.lines.isEmpty {
                    sections.append(current)
                }

                // Parse header level
                let trimmed = line.drop(while: { $0 == "#" })
                let level = line.count - trimmed.count
                let headerText = String(trimmed).trimmingCharacters(in: .whitespaces)

                // Build header stack: keep headers at higher levels, replace at current
                var newHeaders = current.headers
                if level <= newHeaders.count {
                    newHeaders = Array(newHeaders.prefix(level - 1))
                }
                newHeaders.append(headerText)

                current = Section(headers: newHeaders, lines: [])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty {
            sections.append(current)
        }

        // Merge small sections and split large ones
        var result: [(text: String, header: String)] = []
        let targetMin = 80
        let targetMax = 500

        var pendingText = ""
        var pendingHeader = ""

        for section in sections {
            let sectionText = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionText.isEmpty else { continue }

            let breadcrumb = section.headers.joined(separator: " > ")
            let wordCount = sectionText.split(separator: " ").count

            if wordCount < targetMin {
                // Merge with pending
                if pendingText.isEmpty {
                    pendingText = sectionText
                    pendingHeader = breadcrumb
                } else {
                    pendingText += "\n\n" + sectionText
                    // Keep the more specific header
                    if !breadcrumb.isEmpty { pendingHeader = breadcrumb }
                }

                // Flush if pending is now large enough
                let pendingWords = pendingText.split(separator: " ").count
                if pendingWords >= targetMin {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
            } else if wordCount > targetMax {
                // Flush pending first
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }

                // Split large section with overlap
                let words = sectionText.split(separator: " ", omittingEmptySubsequences: true)
                let overlap = targetMax / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMax, words.count)
                    let chunk = words[start..<end].joined(separator: " ")
                    result.append((text: chunk, header: breadcrumb))
                    start += targetMax - overlap
                }
            } else {
                // Flush pending first
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
                result.append((text: sectionText, header: breadcrumb))
            }
        }

        // Flush remaining
        if !pendingText.isEmpty {
            result.append((text: pendingText, header: pendingHeader))
        }

        // If no chunks were produced (e.g. no headers, short doc), chunk the whole text
        if result.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            if words.count <= targetMax {
                result.append((text: text.trimmingCharacters(in: .whitespacesAndNewlines), header: ""))
            } else {
                let overlap = targetMax / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMax, words.count)
                    let chunk = words[start..<end].joined(separator: " ")
                    result.append((text: chunk, header: ""))
                    start += targetMax - overlap
                }
            }
        }

        return result
    }

    // MARK: - Embedding Config Fingerprint

    /// Returns a string that uniquely identifies the current embedding configuration.
    /// Any change (provider, model, URL) produces a different fingerprint, invalidating the cache.
    private func embeddingConfigFingerprint() -> String {
        switch settings.embeddingProvider {
        // "n1" suffix denotes normalized embeddings stored in cache (added with Accelerate refactor).
        // Changing this value invalidates all existing caches and forces a full re-embed.
        case .voyageAI:
            return "voyageAI|n1"
        case .ollama:
            return "ollama|\(settings.ollamaBaseURL)|\(settings.ollamaEmbedModel)|n1"
        case .openAICompatible:
            return "openAI|\(settings.openAIEmbedBaseURL)|\(settings.openAIEmbedModel)|n1"
        }
    }

    // MARK: - Embedding Dispatch

    /// Embeds texts using the currently configured provider.
    private func embedTexts(_ texts: [String], inputType: String) async throws -> [[Float]] {
        switch settings.embeddingProvider {
        case .voyageAI:
            return try await voyageClient.embed(
                apiKey: settings.voyageApiKey,
                texts: texts,
                inputType: inputType
            )
        case .ollama:
            return try await ollamaEmbedClient.embed(
                texts: texts,
                baseURL: settings.ollamaBaseURL,
                model: settings.ollamaEmbedModel
            )
        case .openAICompatible:
            return try await ollamaEmbedClient.embed(
                texts: texts,
                baseURL: settings.openAIEmbedBaseURL,
                model: settings.openAIEmbedModel,
                apiKey: settings.openAIEmbedApiKey
            )
        }
    }

    // MARK: - Embedding Batches

    func finishIndexing(chunks: [KBChunk], fileCount: Int) {
        self.chunks = chunks
        self.fileCount = fileCount
        self.isIndexed = true
        showCompletedStatus(total: chunks.count)
    }

    func failIndexing(message: String, availableChunks: [KBChunk] = [], fileCount: Int? = nil) {
        if let fileCount {
            self.fileCount = fileCount
        }

        if availableChunks.isEmpty {
            chunks.removeAll()
            isIndexed = false
        } else {
            chunks = availableChunks
            isIndexed = true
        }

        indexingStatus = .failed(message: message)
    }

    private func showCompletedStatus(total: Int) {
        let generation = indexGeneration
        let completedStatus = KnowledgeBaseIndexingStatus.completed(total: total)
        indexingStatus = completedStatus

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.indexGeneration == generation, self.indexingStatus == completedStatus else { return }
            self.indexingStatus = .idle
        }
    }

    private func embedInBatches(texts: [String], generation: UUID) async -> (embeddings: [[Float]?], error: String?) {
        let batchSize = 32
        let batches = stride(from: 0, to: texts.count, by: batchSize).map { start in
            Array(texts[start..<min(start + batchSize, texts.count)])
        }

        if settings.embeddingProvider == .ollama {
            return await embedBatchesConcurrently(batches, total: texts.count, batchSize: batchSize, generation: generation)
        } else {
            return await embedBatchesSequentially(batches, total: texts.count, batchSize: batchSize, generation: generation)
        }
    }

    private func embedBatchesConcurrently(_ batches: [[String]], total: Int, batchSize: Int, generation: UUID) async -> (embeddings: [[Float]?], error: String?) {
        if total > 0 {
            indexingStatus = .embedding(completed: 0, total: total, activeRange: 1...min(batchSize, total))
        }
        typealias Indexed = (order: Int, embeddings: [[Float]]?, batchCount: Int)
        let results: [Indexed] = await withTaskGroup(of: Indexed.self) { group in
            for (i, batch) in batches.enumerated() {
                group.addTask {
                    for attempt in 0..<2 {
                        if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                        guard await self.isCurrentIndex(generation) else { return (i, nil, batch.count) }
                        if let embs = try? await self.embedTexts(batch, inputType: "document") {
                            return (i, embs, batch.count)
                        }
                    }
                    return (i, nil, batch.count)
                }
            }
            var collected: [Indexed] = []
            var completed = 0
            for await r in group {
                collected.append(r)
                if let embeddings = r.embeddings, isCurrentIndex(generation) {
                    completed += embeddings.count
                    indexingStatus = .embedding(completed: min(completed, total), total: total, activeRange: nil)
                }
            }
            return collected.sorted { $0.order < $1.order }
        }

        var ordered: [[Float]?] = []
        var lastError: String?
        for result in results {
            if let embs = result.embeddings {
                ordered.append(contentsOf: embs.map { Optional($0) })
            } else {
                ordered.append(contentsOf: Array(repeating: nil as [Float]?, count: result.batchCount))
                lastError = "One or more embedding batches failed"
            }
        }
        return (ordered, lastError)
    }

    private func embedBatchesSequentially(_ batches: [[String]], total: Int, batchSize: Int, generation: UUID) async -> (embeddings: [[Float]?], error: String?) {
        var allEmbeddings: [[Float]?] = []
        var offset = 0
        var lastError: String?
        for batch in batches {
            guard isCurrentIndex(generation) else { return (allEmbeddings, nil) }
            let rangeStart = offset + 1
            let rangeEnd = offset + batch.count
            indexingStatus = .embedding(completed: offset, total: total, activeRange: rangeStart...rangeEnd)
            var retried = false
            var succeeded = false
            while true {
                guard isCurrentIndex(generation) else { return (allEmbeddings, nil) }
                do {
                    let embeddings = try await embedTexts(batch, inputType: "document")
                    guard isCurrentIndex(generation) else { return (allEmbeddings, nil) }
                    allEmbeddings.append(contentsOf: embeddings.map { Optional($0) })
                    offset += embeddings.count
                    indexingStatus = .embedding(completed: min(offset, total), total: total, activeRange: nil)
                    succeeded = true
                    break
                } catch {
                    if !retried {
                        retried = true
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    lastError = error.localizedDescription
                    break
                }
            }
            if !succeeded {
                allEmbeddings.append(contentsOf: Array(repeating: nil as [Float]?, count: batch.count))
                offset += batch.count
            }
        }
        return (allEmbeddings, lastError)
    }

    // MARK: - Vector Math

    /// Returns the dot product of two pre-normalized (unit) vectors, which equals cosine similarity.
    /// Both inputs must already be unit vectors — call `normalizeEmbedding` first.
    private nonisolated func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Returns a unit-length copy of `v` using SIMD-accelerated vDSP operations.
    /// Pre-normalizing embeddings at index time means each search query pays only a dot product.
    private nonisolated static func normalizeEmbedding(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var sumOfSquares: Float = 0
        vDSP_svesq(v, 1, &sumOfSquares, vDSP_Length(v.count))
        let mag = sqrt(sumOfSquares)
        guard mag > 0 else { return v }
        var scale = 1.0 / mag
        var result = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &result, 1, vDSP_Length(v.count))
        return result
    }

    // MARK: - Cache

    private func loadCache() -> KBCache {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cache = try? JSONDecoder().decode(KBCache.self, from: data),
              cache.formatVersion == 1 else {
            return KBCache(entries: [:])
        }
        return cache
    }

    private func saveCache(_ cache: KBCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let url = cacheFileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isCurrentIndex(_ generation: UUID) -> Bool {
        indexGeneration == generation
            && indexedFolderPaths == Self.canonicalFolderPaths(settings.kbFolderURLs)
            && indexedFingerprint == embeddingConfigFingerprint()
    }

    private func ensureSearchReady() async {
        let urls = settings.kbFolderURLs
        if indexedFolderPaths != Self.canonicalFolderPaths(urls) || indexedFingerprint != embeddingConfigFingerprint() {
            clear()
        }
        guard !isIndexed else { return }
        if await loadCachedStateIfAvailable(folderURLs: urls) { return }
        await index(folderURLs: urls)
    }

    // MARK: - Hashing

    private nonisolated static func sha256Static(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func canonicalFolderPaths(_ urls: [URL]) -> [String] {
        Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })).sorted()
    }
}
