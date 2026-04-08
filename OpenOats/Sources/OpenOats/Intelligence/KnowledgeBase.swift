import Accelerate
import Foundation
import CryptoKit

/// A chunk of text from a knowledge base document.
struct KBChunk: Codable, Sendable {
    let text: String
    let sourceFile: String
    let headerContext: String
    let embedding: [Float]
    let relativePath: String     // e.g. "sales/pricing.md"
    let folderBreadcrumb: String // e.g. "sales"
    let documentTitle: String    // first H1 or filename sans extension

    init(text: String, sourceFile: String, headerContext: String, embedding: [Float], relativePath: String = "", folderBreadcrumb: String = "", documentTitle: String = "") {
        self.text = text
        self.sourceFile = sourceFile
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
        headerContext = try container.decode(String.self, forKey: .headerContext)
        embedding = try container.decode([Float].self, forKey: .embedding)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? sourceFile
        folderBreadcrumb = try container.decodeIfPresent(String.self, forKey: .folderBreadcrumb) ?? ""
        documentTitle = try container.decodeIfPresent(String.self, forKey: .documentTitle) ?? sourceFile
    }
}

/// Disk cache format for embedded KB chunks.
private struct KBCache: Codable, Sendable {
    /// Keyed by "filename:sha256hash"
    var entries: [String: [KBChunk]]
    /// Fingerprint of the embedding config used to produce these vectors.
    var embeddingConfigFingerprint: String?
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

    @ObservationIgnored nonisolated(unsafe) private var _indexingProgress = ""
    private(set) var indexingProgress: String {
        get { access(keyPath: \.indexingProgress); return _indexingProgress }
        set { withMutation(keyPath: \.indexingProgress) { _indexingProgress = newValue } }
    }

    private let settings: AppSettings
    private let voyageClient = VoyageClient()
    private let ollamaEmbedClient = OllamaEmbedClient()

    private nonisolated static func cacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenOats")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kb_cache.json")
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func index(folderURL: URL) async {
        let provider = settings.embeddingProvider

        // Validate credentials based on provider
        if provider == .voyageAI {
            guard !settings.voyageApiKey.isEmpty else {
                indexingProgress = "No Voyage AI API key"
                return
            }
        }

        indexingProgress = "Scanning files..."

        // Load existing cache; invalidate if embedding config changed
        let fingerprint = embeddingConfigFingerprint()
        var cache = loadCache()
        if cache.embeddingConfigFingerprint != fingerprint {
            cache = KBCache(entries: [:], embeddingConfigFingerprint: fingerprint)
        }

        // Move all blocking file I/O off the main thread
        let cacheSnapshot = cache
        let scanResult = await Task.detached {
            Self.scanFiles(in: folderURL, cache: cacheSnapshot)
        }.value

        guard !scanResult.fileURLs.isEmpty else {
            indexingProgress = ""
            isIndexed = true
            return
        }

        var allChunks = scanResult.cachedChunks
        var filesToEmbed = scanResult.filesToEmbed

        // Embed new/changed files in batches
        if !filesToEmbed.isEmpty {
            let allTextsToEmbed = filesToEmbed.flatMap { entry in
                entry.chunks.map { chunk in
                    var prefix = entry.relativePath
                    if !chunk.header.isEmpty { prefix += " > \(chunk.header)" }
                    return "\(prefix)\n\(chunk.text)"
                }
            }

            indexingProgress = "Embedding \(allTextsToEmbed.count) chunks..."

            let result = await embedInBatches(texts: allTextsToEmbed)
            let embeddings = result.embeddings

            if embeddings == nil, let errMsg = result.error {
                indexingProgress = "Embed error: \(errMsg)"
            }

            if let embeddings {
                var offset = 0
                for entry in filesToEmbed {
                    var fileChunks: [KBChunk] = []
                    for chunk in entry.chunks {
                        let embedding = embeddings[offset]
                        let fileName = entry.key.components(separatedBy: ":").first ?? ""
                        let kbChunk = KBChunk(
                            text: chunk.text,
                            sourceFile: fileName,
                            headerContext: chunk.header,
                            embedding: Self.normalizeEmbedding(embedding),
                            relativePath: entry.relativePath,
                            folderBreadcrumb: entry.folderBreadcrumb,
                            documentTitle: entry.documentTitle
                        )
                        fileChunks.append(kbChunk)
                        offset += 1
                    }
                    cache.entries[entry.key] = fileChunks
                    allChunks.append(contentsOf: fileChunks)
                }

                // Prune stale cache entries using pre-computed keys
                let allRelevantKeys = Set(filesToEmbed.map(\.key)).union(scanResult.currentCacheKeys)
                cache.entries = cache.entries.filter { allRelevantKeys.contains($0.key) }

                saveCache(cache)
            }
        } else {
            // All files were cached — still prune stale entries
            if cache.entries.keys.count != scanResult.currentCacheKeys.count {
                cache.entries = cache.entries.filter { scanResult.currentCacheKeys.contains($0.key) }
                saveCache(cache)
            }
        }

        self.chunks = allChunks
        self.fileCount = scanResult.fileCount
        self.isIndexed = true
        self.indexingProgress = ""
    }

    // MARK: - Background File Scanning

    private struct FileScanResult: Sendable {
        let fileURLs: [URL]
        let fileCount: Int
        let cachedChunks: [KBChunk]
        let filesToEmbed: [FileToEmbed]
        let currentCacheKeys: Set<String>
    }

    private struct FileToEmbed: Sendable {
        let key: String
        let chunks: [(text: String, header: String)]
        let relativePath: String
        let folderBreadcrumb: String
        let documentTitle: String
    }

    /// Reads all KB files off the main thread. Pure file I/O — no actor-isolated state.
    private nonisolated static func scanFiles(in folderURL: URL, cache: KBCache) -> FileScanResult {
        let fileURLs = collectFilesStatic(in: folderURL)
        guard !fileURLs.isEmpty else {
            return FileScanResult(fileURLs: [], fileCount: 0, cachedChunks: [], filesToEmbed: [], currentCacheKeys: [])
        }

        var cachedChunks: [KBChunk] = []
        var filesToEmbed: [FileToEmbed] = []
        var fileCount = 0
        var currentCacheKeys = Set<String>()

        for fileURL in fileURLs {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            fileCount += 1

            let fileName = fileURL.lastPathComponent
            let hash = sha256Static(content)
            let cacheKey = "\(fileName):\(hash)"
            currentCacheKeys.insert(cacheKey)

            // Reuse cached embeddings if content hasn't changed
            if let cached = cache.entries[cacheKey] {
                cachedChunks.append(contentsOf: cached)
                continue
            }

            let relativePath = fileURL.path.hasPrefix(folderURL.path)
                ? String(fileURL.path.dropFirst(folderURL.path.count).drop(while: { $0 == "/" }))
                : fileName

            let folderBreadcrumb = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
                .trimmingCharacters(in: CharacterSet(charactersIn: "./"))

            let docTitle = extractDocumentTitleStatic(from: content) ?? fileName.replacingOccurrences(of: ".\(fileURL.pathExtension)", with: "")

            let textChunks = chunkMarkdownStatic(content, sourceFile: fileName)
            filesToEmbed.append(FileToEmbed(key: cacheKey, chunks: textChunks, relativePath: relativePath, folderBreadcrumb: folderBreadcrumb, documentTitle: docTitle))
        }

        return FileScanResult(fileURLs: fileURLs, fileCount: fileCount, cachedChunks: cachedChunks, filesToEmbed: filesToEmbed, currentCacheKeys: currentCacheKeys)
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
            let prevSibling: String? = chunkIndex > 0 && chunks[chunkIndex - 1].sourceFile == result.sourceFile
                ? chunks[chunkIndex - 1].text : nil
            let nextSibling: String? = chunkIndex < chunks.count - 1 && chunks[chunkIndex + 1].sourceFile == result.sourceFile
                ? chunks[chunkIndex + 1].text : nil
            let chunk = chunks[chunkIndex]
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
        let provider = settings.embeddingProvider
        guard isIndexed, !chunks.isEmpty else { return [] }

        if provider == .voyageAI {
            guard !settings.voyageApiKey.isEmpty else { return [] }
        }

        let validQueries = queries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validQueries.isEmpty else { return [] }

        let queryEmbeddings: [[Float]]
        do {
            queryEmbeddings = try await embedTexts(validQueries, inputType: "query")
        } catch {
            print("KB search embed error: \(error)")
            return []
        }

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
                print("KB rerank error (falling back to cosine): \(error)")
            }
        }

        // Cosine-similarity fallback (used by Ollama or when Voyage rerank fails)
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
        chunks.removeAll()
        isIndexed = false
        fileCount = 0
        indexingProgress = ""
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
            if ext == "md" || ext == "txt" {
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

    private func embedInBatches(texts: [String]) async -> (embeddings: [[Float]]?, error: String?) {
        let batchSize = 32
        let batches = stride(from: 0, to: texts.count, by: batchSize).map { start in
            Array(texts[start..<min(start + batchSize, texts.count)])
        }

        // Ollama is local with no rate limits — fire all batches concurrently.
        // Cloud providers (Voyage, OpenAI-compatible) are rate-limited, keep sequential.
        if settings.embeddingProvider == .ollama {
            return await embedBatchesConcurrently(batches, total: texts.count)
        } else {
            return await embedBatchesSequentially(batches, total: texts.count)
        }
    }

    private func embedBatchesConcurrently(_ batches: [[String]], total: Int) async -> (embeddings: [[Float]]?, error: String?) {
        indexingProgress = "Embedding \(total) chunks..."
        typealias Indexed = (order: Int, embeddings: [[Float]]?)
        let results: [Indexed] = await withTaskGroup(of: Indexed.self) { group in
            for (i, batch) in batches.enumerated() {
                group.addTask {
                    for attempt in 0..<2 {
                        if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                        if let embs = try? await self.embedTexts(batch, inputType: "document") {
                            return (i, embs)
                        }
                    }
                    return (i, nil)
                }
            }
            var collected: [Indexed] = []
            for await r in group { collected.append(r) }
            return collected.sorted { $0.order < $1.order }
        }
        guard !results.contains(where: { $0.embeddings == nil }) else {
            return (nil, "One or more embedding batches failed")
        }
        return (results.flatMap { $0.embeddings! }, nil)
    }

    private func embedBatchesSequentially(_ batches: [[String]], total: Int) async -> (embeddings: [[Float]]?, error: String?) {
        var allEmbeddings: [[Float]] = []
        var offset = 0
        for batch in batches {
            let end = offset + batch.count
            indexingProgress = "Embedding \(offset + 1)-\(end) of \(total)..."
            var retried = false
            while true {
                do {
                    let embeddings = try await embedTexts(batch, inputType: "document")
                    allEmbeddings.append(contentsOf: embeddings)
                    break
                } catch {
                    if !retried {
                        retried = true
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    return (nil, error.localizedDescription)
                }
            }
            offset = end
        }
        return (allEmbeddings, nil)
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

    private nonisolated func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheURL())
    }

    private nonisolated func loadCache() -> KBCache {
        guard let data = try? Data(contentsOf: Self.cacheURL()),
              let cache = try? JSONDecoder().decode(KBCache.self, from: data) else {
            return KBCache(entries: [:])
        }
        return cache
    }

    private nonisolated func saveCache(_ cache: KBCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let url = Self.cacheURL()
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Hashing

    private nonisolated static func sha256Static(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
