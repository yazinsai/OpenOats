# Real-Time Suggestion Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5-stage serial suggestion pipeline with a 3-layer concurrent architecture that delivers KB-backed suggestions within 2 seconds of a conversational trigger.

**Architecture:** Three concurrent layers — (1) continuous context accumulator with periodic KB pre-fetching on incremental speech, (2) instant retrieval with a local heuristic gate, (3) streaming LLM synthesis. The existing `OverlayPanel` is repurposed as a floating side panel. The current transcription path does not yet emit useful partial hypotheses, so this plan explicitly adds throttled best-effort partial emission in `StreamingTranscriber.swift` and plumbs it through `TranscriptionEngine.swift` before any pre-fetch work relies on it.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26+, SPM. Existing dependencies: FluidAudio (transcription), Sparkle (updates). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-03-26-realtime-suggestions-design.md`

**Codebase convention:** All `@Observable @MainActor` classes use `@ObservationIgnored nonisolated(unsafe)` backing stores with manual `access(keyPath:)`/`withMutation(keyPath:)` tracking — required for Swift 6.2 SwiftUI compatibility. Follow this pattern exactly for every new observable property.

**Existing overlay infrastructure:** `OverlayPanel.swift` already has a floating `NSPanel` subclass with `.nonactivatingPanel`, `.floating` level, screen-share hiding, and `setFrameAutosaveName`. `OverlayManager` manages its lifecycle. These will be extended rather than replaced.

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `Intelligence/PreFetchCache.swift` | Caches recent KB search results keyed by text fingerprint. TTL-based eviction. |
| `Intelligence/RealtimeGate.swift` | Local heuristic gate: question detection, KB score check, duplicate suppression. |
| `Intelligence/BurstDecayThrottle.swift` | Drop-or-display pacing based on question density + KB match quality. |
| `Views/SuggestionPanelContent.swift` | SwiftUI content view for the floating suggestion panel. |

### Modified Files

| File | Change Summary |
|------|---------------|
| `Models/Models.swift` | Add `KBContextPack`, `RealtimeSuggestionCandidate`, `SuggestionLifecycle`, `RealtimeTriggerKind`, and stable suggestion identity fields on `SessionRecord`. |
| `Settings/SettingsStore.swift` | Add `realtimeModel`, `realtimeOllamaModel`, `suggestionPanelEnabled`, `preFetchIntervalSeconds`, `kbSimilarityThreshold`, and provider-aware realtime model helpers. |
| `Models/TranscriptStore.swift` | Add question density tracking, rolling partial/final text windows, and state-update tracking from either speaker without regressing diarized remote speakers. |
| `Transcription/StreamingTranscriber.swift` | Emit throttled best-effort partial hypotheses during active speech instead of finals only. |
| `Transcription/TranscriptionEngine.swift` | Plumb mic + system partial callbacks into `TranscriptStore` and clear partial state correctly on finalization/restart. |
| `Intelligence/KnowledgeBase.swift` | Return `KBContextPack` with relative path, folder breadcrumb, header breadcrumb, adjacent chunks, and cached context-pack lookup helpers. |
| `Intelligence/SuggestionEngine.swift` | **Full rewrite.** 3-layer concurrent architecture plus compatibility/logging shims during rollout. |
| `Storage/SessionRepository.swift` | Persist suggestion identity by `suggestionID` + `triggerUtteranceID` instead of snapshotting the latest suggestion. |
| `App/LiveSessionController.swift` | Trigger suggestions from either speaker, route delayed writes for both-speaker logging, and drive suggestion-panel refresh callbacks. |
| `Views/OverlayPanel.swift` | Extend `OverlayManager` to support side-panel mode (250px wide, docked right, auto-show/hide). |
| `Views/ContentView.swift` | Remove inline `SuggestionsView` section. Wire the panel through `LiveSessionController` callbacks and build panel content from realtime suggestions. |
| `Views/SettingsView.swift` | Add "Real-Time Suggestions" section with new settings. |
| `App/OpenOatsApp.swift` | Extend the existing global/local hotkey infrastructure with `Cmd+Shift+O` to toggle the panel. |

### Deleted/Deprecated

| File | Status |
|------|--------|
| `Views/OverlayContent.swift` | Replaced by `SuggestionPanelContent.swift`. Delete after Task 11. |
| `Views/SuggestionsView.swift` | No longer used in ContentView. Delete after Task 12. |

---

### Task 1: New Data Models

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Models/Models.swift`

- [ ] **Step 1: Add `RealtimeTriggerKind` enum**

Add below the existing `SuggestionTriggerKind` enum:

```swift
/// Collapsed trigger categories for the real-time pipeline.
enum RealtimeTriggerKind: String, Codable, Sendable {
    case question   // maps from: explicitQuestion, decisionPoint
    case claim      // maps from: assumption, disagreement
    case topic      // maps from: customerProblem, distributionGoToMarket, productScope, prioritization
    case general    // fallback

    init(from legacy: SuggestionTriggerKind) {
        switch legacy {
        case .explicitQuestion, .decisionPoint: self = .question
        case .assumption, .disagreement: self = .claim
        case .customerProblem, .distributionGoToMarket, .productScope, .prioritization: self = .topic
        case .unclear: self = .general
        }
    }
}
```

- [ ] **Step 2: Add `KBContextPack` struct**

Add after `KBResult`:

```swift
/// Rich KB context preserving document structure for display and synthesis.
struct KBContextPack: Identifiable, Sendable, Codable {
    let id: UUID
    let matchedText: String
    let relativePath: String      // e.g. "sales/pricing.md"
    let folderBreadcrumb: String  // e.g. "sales"
    let documentTitle: String     // first H1 or filename
    let headerBreadcrumb: String  // e.g. "Pricing > Unit Economics"
    let score: Double
    let previousSiblingText: String?
    let nextSiblingText: String?

    init(
        matchedText: String,
        relativePath: String,
        folderBreadcrumb: String = "",
        documentTitle: String = "",
        headerBreadcrumb: String = "",
        score: Double,
        previousSiblingText: String? = nil,
        nextSiblingText: String? = nil
    ) {
        self.id = UUID()
        self.matchedText = matchedText
        self.relativePath = relativePath
        self.folderBreadcrumb = folderBreadcrumb
        self.documentTitle = documentTitle
        self.headerBreadcrumb = headerBreadcrumb
        self.score = score
        self.previousSiblingText = previousSiblingText
        self.nextSiblingText = nextSiblingText
    }

    /// Display breadcrumb: "sales/pricing.md > Pricing > Unit Economics"
    var displayBreadcrumb: String {
        var parts: [String] = []
        if !relativePath.isEmpty { parts.append(relativePath) }
        if !headerBreadcrumb.isEmpty { parts.append(headerBreadcrumb) }
        return parts.joined(separator: " > ")
    }
}
```

- [ ] **Step 3: Add `SuggestionLifecycle` and `RealtimeSuggestion`**

```swift
enum SuggestionLifecycle: String, Codable, Sendable {
    case raw         // KB snippet shown, no LLM yet
    case streaming   // LLM synthesis in progress
    case completed   // LLM synthesis finished
    case failed      // LLM call failed, raw snippet preserved
    case superseded  // Replaced by a newer suggestion
}

/// A real-time suggestion with stable identity across its lifecycle.
struct RealtimeSuggestion: Identifiable, Sendable {
    let id: UUID
    let triggerKind: RealtimeTriggerKind
    let triggerExcerpt: String
    let triggerUtteranceID: UUID?
    let contextPacks: [KBContextPack]
    let candidateScore: Double
    let createdAt: Date
    var lifecycle: SuggestionLifecycle
    var synthesizedText: String  // empty in .raw, streams in during .streaming
    var rawSnippet: String       // first context pack's matched text

    init(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        triggerUtteranceID: UUID? = nil,
        contextPacks: [KBContextPack],
        candidateScore: Double
    ) {
        self.id = UUID()
        self.triggerKind = triggerKind
        self.triggerExcerpt = triggerExcerpt
        self.triggerUtteranceID = triggerUtteranceID
        self.contextPacks = contextPacks
        self.candidateScore = candidateScore
        self.createdAt = .now
        self.lifecycle = .raw
        self.synthesizedText = ""
        self.rawSnippet = contextPacks.first?.matchedText ?? ""
    }

    /// The best available text for display.
    var displayText: String {
        synthesizedText.isEmpty ? rawSnippet : synthesizedText
    }

    /// The primary source breadcrumb for display.
    var sourceBreadcrumb: String {
        contextPacks.first?.displayBreadcrumb ?? ""
    }
}
```

- [ ] **Step 4: Add `RealtimeSuggestionCandidate`**

```swift
/// Output of the local heuristic gate — passed to Layer 3 for synthesis.
struct RealtimeSuggestionCandidate: Sendable {
    let candidateID: UUID
    let triggerKind: RealtimeTriggerKind
    let triggerExcerpt: String
    let triggerUtteranceID: UUID?
    let contextPacks: [KBContextPack]
    let score: Double
    let createdAt: Date

    init(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        triggerUtteranceID: UUID? = nil,
        contextPacks: [KBContextPack],
        score: Double
    ) {
        self.candidateID = UUID()
        self.triggerKind = triggerKind
        self.triggerExcerpt = triggerExcerpt
        self.triggerUtteranceID = triggerUtteranceID
        self.contextPacks = contextPacks
        self.score = score
        self.createdAt = .now
    }
}
```

- [ ] **Step 5: Extend `SessionRecord` for stable suggestion logging**

Update `SessionRecord` in the same file to persist the identity of the suggestion that was actually surfaced for a specific utterance.

Add fields for:

- `suggestionID: UUID?`
- `triggerUtteranceID: UUID?`
- `suggestionLifecycle: SuggestionLifecycle?`

Keep existing human-readable fields such as `suggestions`, `kbHits`, and `surfacedSuggestionText` for backwards compatibility with current history readers, but treat the new identity fields as the source of truth for delayed logging.

- [ ] **Step 6: Build to verify compilation**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (new types are unused — that's fine for now)

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Models/Models.swift
git commit -m "feat: add real-time suggestion data models

KBContextPack, RealtimeSuggestion with lifecycle tracking,
RealtimeSuggestionCandidate, and RealtimeTriggerKind."
```

---

### Task 2: SettingsStore Additions

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`

`AppSettings` is currently a typealias to `SettingsStore`, so patch `SettingsStore.swift` directly.

- [ ] **Step 1: Add new persisted settings**

Add persisted backing stores + accessors for:

- `realtimeModel`
- `realtimeOllamaModel`
- `suggestionPanelEnabled`
- `preFetchIntervalSeconds`
- `kbSimilarityThreshold`

Implementation rules:

- Follow the existing `@ObservationIgnored nonisolated(unsafe)` pattern exactly.
- Persist through the injected `defaults` instance already held by `SettingsStore`, not `UserDefaults.standard`.
- Keep using the existing `hideFromScreenShare` setting name; do not introduce a second screen-share visibility flag.

- [ ] **Step 2: Initialize them in `SettingsStore.init()`**

Initialize the new properties alongside the existing persisted settings using the same defaults-handling style already used elsewhere in the file.

Default values:

- `realtimeModel = "google/gemini-2.0-flash-001"`
- `realtimeOllamaModel = ""`
- `suggestionPanelEnabled = true`
- `preFetchIntervalSeconds = 4.0`
- `kbSimilarityThreshold = 0.35`

- [ ] **Step 3: Add provider-aware realtime model helpers**

Add `activeRealtimeModel` and `activeRealtimeModelDisplay` helpers.

Behavior:

- `.openRouter`: use `realtimeModel`
- `.ollama`: use `realtimeOllamaModel` when non-empty, otherwise `ollamaLLMModel`
- `.mlx`: reuse `mlxModel` for now
- `.openAICompatible`: reuse `openAILLMModel` for now

Do not leave the switch non-exhaustive.

- [ ] **Step 4: Update any intentional settings migration lists**

If the existing settings migration paths are supposed to carry these new keys forward from prior bundle IDs, add the keys there as part of the same task.

- [ ] **Step 5: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift
git commit -m "feat: add real-time suggestion settings to SettingsStore

realtimeModel, realtimeOllamaModel, suggestionPanelEnabled,
preFetchIntervalSeconds, and kbSimilarityThreshold."
```

---

### Task 3: TranscriptStore Additions

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Models/TranscriptStore.swift`

- [ ] **Step 1: Add question-density state**

Add rolling timestamp arrays for:

- recent utterances in the last 60 seconds
- recent question-bearing utterances in the last 60 seconds

Also add a computed `questionDensity` that prunes stale timestamps and returns the ratio.

- [ ] **Step 2: Add question detection helpers**

Add:

- a small set of question-leading keywords
- a non-`mutating` `pruneTimestamps()` helper (this is a class, not a struct)
- an `isQuestion(_:)` helper

- [ ] **Step 3: Update `append(_:)` against the current store**

Patch the real current implementation, not the older `.them`-only version.

Implementation rules:

- Keep the acoustic-echo suppression guard unchanged.
- Track question density for utterances from both speakers.
- Preserve `speaker.isRemote` semantics so diarized remote speakers still count as remote.
- Increment the existing remote-only counter and a new `utterancesSinceStateUpdate` counter.

- [ ] **Step 4: Add state-refresh tracking from either speaker**

Add:

- `utterancesSinceStateUpdate`
- `needsStateUpdateFromEitherSpeaker`

Update both `clear()` and `updateConversationState(_:)` to reset:

- `remoteUtterancesSinceStateUpdate`
- `utterancesSinceStateUpdate`
- both timestamp arrays

Keep the existing remote-only `needsStateUpdate` helper if other code still depends on it during rollout.

- [ ] **Step 5: Add combined partial/final text windows**

Add:

- `combinedPartialText`
- `recentTextWindow`
- `preFetchQueryText`

Implementation rules:

- Use `speaker.displayLabel` when building the final-text window so diarized remote speakers stay distinct.
- Prefer partial text when available, otherwise fall back to the recent finalized window.

- [ ] **Step 6: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Models/TranscriptStore.swift
git commit -m "feat: add question density tracking and partial/final text windows to TranscriptStore"
```

---

### Task 3A: Incremental Transcript Emission

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Transcription/StreamingTranscriber.swift`
- Modify: `OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift`

Layer 1 cannot rely on partials until the live transcription path actually emits them. Implement best-effort partial hypotheses here before any pre-fetch work depends on them.

- [ ] **Step 1: Add throttled partial emission in `StreamingTranscriber`**

Implementation rules:

- While speech is active, periodically run a best-effort decode over the accumulated in-flight speech buffer and send the result through `onPartial`.
- Throttle partial attempts to roughly every 250-500ms.
- Do not allow overlapping partial-decode tasks.
- Do not append utterances or advance final-segment state from partial decodes.
- Clear partial output on speech end, cancellation, and final delivery.

- [ ] **Step 2: Plumb partial callbacks through `TranscriptionEngine`**

Implementation rules:

- Update both mic and system-audio paths to keep `volatileYouText` / `volatileThemText` current from partial callbacks.
- Clear those partial strings on final utterance delivery, stop, restart, and session clear.
- Keep final utterance append semantics unchanged.

- [ ] **Step 3: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Transcription/StreamingTranscriber.swift OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift
git commit -m "feat: add throttled partial transcript emission for real-time suggestions"
```

---

### Task 4: KnowledgeBase — KBContextPack Support

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/KnowledgeBase.swift`

- [ ] **Step 1: Add chunk index tracking to `KBChunk`**

Modify `KBChunk` to include its index in the chunks array and relative path:

```swift
struct KBChunk: Codable, Sendable {
    let text: String
    let sourceFile: String
    let headerContext: String
    let embedding: [Float]
    let relativePath: String     // e.g. "sales/pricing.md"
    let folderBreadcrumb: String // e.g. "sales"
    let documentTitle: String    // first H1 or filename sans extension
}
```

- [ ] **Step 2: Update `index(folderURL:)` to populate new fields**

In the file-embedding loop, capture the folder-relative path. Replace the chunk construction in the embedding results processing (the `for entry in filesToEmbed` loop). Find the section where `KBChunk` instances are created:

```swift
let kbChunk = KBChunk(
    text: chunk.text,
    sourceFile: entry.key.components(separatedBy: ":").first ?? "",
    headerContext: chunk.header,
    embedding: embedding
)
```

Replace with:

```swift
let fileName = entry.key.components(separatedBy: ":").first ?? ""
let kbChunk = KBChunk(
    text: chunk.text,
    sourceFile: fileName,
    headerContext: chunk.header,
    embedding: embedding,
    relativePath: entry.relativePath,
    folderBreadcrumb: entry.folderBreadcrumb,
    documentTitle: entry.documentTitle
)
```

This requires updating the `filesToEmbed` tuple type. Change:

```swift
var filesToEmbed: [(key: String, chunks: [(text: String, header: String)])] = []
```

To:

```swift
var filesToEmbed: [(key: String, chunks: [(text: String, header: String)], relativePath: String, folderBreadcrumb: String, documentTitle: String)] = []
```

And update where entries are appended — compute the relative path from the KB folder root:

```swift
let relativePath = fileURL.path.hasPrefix(folderURL.path)
    ? String(fileURL.path.dropFirst(folderURL.path.count).drop(while: { $0 == "/" }))
    : fileName

let folderBreadcrumb = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
    .trimmingCharacters(in: CharacterSet(charactersIn: "./"))

let docTitle = extractDocumentTitle(from: content) ?? fileName.replacingOccurrences(of: ".\(fileURL.pathExtension)", with: "")

filesToEmbed.append((key: cacheKey, chunks: textChunks, relativePath: relativePath, folderBreadcrumb: folderBreadcrumb, documentTitle: docTitle))
```

- [ ] **Step 3: Add document title extraction helper**

```swift
/// Extracts the first H1 heading from markdown content, or nil.
private nonisolated func extractDocumentTitle(from content: String) -> String? {
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}
```

- [ ] **Step 4: Add embedding metadata prefix**

In `embedInBatches`, the texts are already formed as `"\($0.header)\n\($0.text)"`. Enhance this to include file/folder metadata. Find in `index(folderURL:)`:

```swift
let allTextsToEmbed = filesToEmbed.flatMap { entry in
    entry.chunks.map { "\($0.header)\n\($0.text)" }
}
```

Replace with:

```swift
let allTextsToEmbed = filesToEmbed.flatMap { entry in
    entry.chunks.map { chunk in
        var prefix = entry.relativePath
        if !chunk.header.isEmpty { prefix += " > \(chunk.header)" }
        return "\(prefix)\n\(chunk.text)"
    }
}
```

- [ ] **Step 5: Add `searchContextPacks` method**

Add a new method that returns `KBContextPack` with adjacent chunk context:

```swift
/// Search returning rich context packs with adjacent sibling text.
func searchContextPacks(queries: [String], topK: Int = 3) async -> [KBContextPack] {
    let results = await search(queries: queries, topK: topK)
    return results.map { result in
        // Find the matching chunk index for adjacent context
        let matchIndex = chunks.firstIndex { $0.text == result.text && $0.sourceFile == result.sourceFile }
        let prevText: String? = matchIndex.flatMap { idx in
            idx > 0 ? chunks[idx - 1].text : nil
        }
        let nextText: String? = matchIndex.flatMap { idx in
            idx < chunks.count - 1 ? chunks[idx + 1].text : nil
        }
        // Only include sibling if it's from the same file
        let prevSibling: String?
        if let mi = matchIndex, mi > 0, chunks[mi - 1].sourceFile == result.sourceFile {
            prevSibling = chunks[mi - 1].text
        } else {
            prevSibling = nil
        }
        let nextSibling: String?
        if let mi = matchIndex, mi < chunks.count - 1, chunks[mi + 1].sourceFile == result.sourceFile {
            nextSibling = chunks[mi + 1].text
        } else {
            nextSibling = nil
        }

        let chunk = matchIndex.map { chunks[$0] }
        return KBContextPack(
            matchedText: result.text,
            relativePath: chunk?.relativePath ?? result.sourceFile,
            folderBreadcrumb: chunk?.folderBreadcrumb ?? "",
            documentTitle: chunk?.documentTitle ?? result.sourceFile,
            headerBreadcrumb: result.headerContext,
            score: result.score,
            previousSiblingText: prevSibling,
            nextSiblingText: nextSibling
        )
    }
}
```

- [ ] **Step 6: Handle cached KBChunk backwards compatibility**

The on-disk `KBCache` stores `[KBChunk]`. Old cached entries won't have the new fields. Add defaults to `KBChunk` for decoding:

```swift
struct KBChunk: Codable, Sendable {
    let text: String
    let sourceFile: String
    let headerContext: String
    let embedding: [Float]
    let relativePath: String
    let folderBreadcrumb: String
    let documentTitle: String

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
```

- [ ] **Step 7: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/KnowledgeBase.swift
git commit -m "feat: KBContextPack support with relative paths, folder breadcrumbs, and adjacent chunks"
```

---

### Task 5: PreFetchCache

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/PreFetchCache.swift`

- [ ] **Step 1: Create the cache**

```swift
import Foundation

/// Caches recent KB search results keyed by a normalized text fingerprint.
/// Thread-safe via actor isolation. Entries expire after a configurable TTL.
actor PreFetchCache {
    struct Entry: Sendable {
        let packs: [KBContextPack]
        let topScore: Double
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttlSeconds: TimeInterval
    private let maxEntries: Int

    init(ttlSeconds: TimeInterval = 30, maxEntries: Int = 20) {
        self.ttlSeconds = ttlSeconds
        self.maxEntries = maxEntries
    }

    /// Store results for a text fingerprint.
    func store(fingerprint: String, packs: [KBContextPack]) {
        let topScore = packs.first?.score ?? 0
        entries[fingerprint] = Entry(packs: packs, topScore: topScore, createdAt: .now)
        evictStale()
    }

    /// Retrieve cached results if they exist and aren't stale.
    func get(fingerprint: String) -> Entry? {
        guard let entry = entries[fingerprint] else { return nil }
        if Date.now.timeIntervalSince(entry.createdAt) > ttlSeconds {
            entries.removeValue(forKey: fingerprint)
            return nil
        }
        return entry
    }

    /// The highest score across all non-stale entries.
    func bestScore() -> Double {
        evictStale()
        return entries.values.map(\.topScore).max() ?? 0
    }

    /// The best non-stale entry.
    func bestEntry() -> Entry? {
        evictStale()
        return entries.values.max(by: { $0.topScore < $1.topScore })
    }

    func clear() {
        entries.removeAll()
    }

    private func evictStale() {
        let cutoff = Date.now.addingTimeInterval(-ttlSeconds)
        entries = entries.filter { $0.value.createdAt > cutoff }
        // Cap size
        if entries.count > maxEntries {
            let sorted = entries.sorted { $0.value.createdAt < $1.value.createdAt }
            let toRemove = sorted.prefix(entries.count - maxEntries)
            for (key, _) in toRemove { entries.removeValue(forKey: key) }
        }
    }

    /// Normalize text into a fingerprint for cache keying.
    /// Lowercases, strips punctuation, and takes the last ~50 words.
    static func fingerprint(_ text: String) -> String {
        let words = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .suffix(50)
        return words.joined(separator: " ")
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/PreFetchCache.swift
git commit -m "feat: add PreFetchCache for periodic KB pre-fetch results"
```

---

### Task 6: RealtimeGate — Local Heuristic Gate

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/RealtimeGate.swift`

- [ ] **Step 1: Create the gate**

```swift
import Foundation

/// Local heuristic gate that decides whether to surface a suggestion.
/// Replaces the LLM-based surfacing gate for sub-100ms decisions.
struct RealtimeGate: Sendable {
    let kbSimilarityThreshold: Double

    /// Evaluate whether a suggestion should surface.
    func evaluate(
        text: String,
        speaker: Speaker,
        contextPacks: [KBContextPack],
        questionDensity: Double,
        recentSuggestionTexts: [String]
    ) -> GateResult {
        let topScore = contextPacks.first?.score ?? 0

        // KB similarity threshold
        guard topScore >= kbSimilarityThreshold else {
            return GateResult(shouldSurface: false, triggerKind: .general, score: topScore, reason: "KB score below threshold")
        }

        // Detect trigger kind
        let triggerKind = detectTriggerKind(text)

        // Duplicate suppression: Jaccard similarity against recent suggestions
        let candidateText = contextPacks.first?.matchedText ?? ""
        for recent in recentSuggestionTexts.suffix(3) {
            if jaccardSimilarity(candidateText, recent) > 0.7 {
                return GateResult(shouldSurface: false, triggerKind: triggerKind, score: topScore, reason: "Duplicate of recent suggestion")
            }
        }

        // Combined score for burst/decay
        let combinedScore = (questionDensity * 0.4) + (topScore * 0.6)

        return GateResult(
            shouldSurface: true,
            triggerKind: triggerKind,
            score: combinedScore,
            reason: "Passed heuristic gate"
        )
    }

    struct GateResult: Sendable {
        let shouldSurface: Bool
        let triggerKind: RealtimeTriggerKind
        let score: Double
        let reason: String
    }

    // MARK: - Trigger Detection

    private func detectTriggerKind(_ text: String) -> RealtimeTriggerKind {
        let lower = text.lowercased()

        // Question markers
        if lower.contains("?") { return .question }
        let questionStarts = ["what ", "how ", "why ", "should ", "could ", "would ", "do you think", "which "]
        for start in questionStarts {
            if lower.hasPrefix(start) { return .question }
        }

        // Decision markers
        let decisionPhrases = ["should we", "let's go with", "i think we should", "we need to decide", "which one"]
        for phrase in decisionPhrases {
            if lower.contains(phrase) { return .question }
        }

        // Claim markers
        let claimPhrases = ["i think", "i assume", "i believe", "probably", "but ", "however", "i disagree", "that's not", "the problem is"]
        for phrase in claimPhrases {
            if lower.contains(phrase) { return .claim }
        }

        // Topic markers
        let topicPhrases = ["customer", "user", "pain point", "market", "distribution", "pricing", "mvp", "feature", "retention", "churn"]
        for phrase in topicPhrases {
            if lower.contains(phrase) { return .topic }
        }

        return .general
    }

    // MARK: - Similarity

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " ").map(String.init))
        let setB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !setA.isEmpty || !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/RealtimeGate.swift
git commit -m "feat: add RealtimeGate — local heuristic gate replacing LLM surfacing gate"
```

---

### Task 7: BurstDecayThrottle

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/BurstDecayThrottle.swift`

- [ ] **Step 1: Create the throttle**

```swift
import Foundation

/// Drop-or-display pacing for real-time suggestions.
/// Candidates either surface immediately, replace the current suggestion, or get dropped.
/// No delayed queue — stale candidates are discarded.
@MainActor
final class BurstDecayThrottle {
    private var lastSuggestionTime: Date?
    private var lastSuggestionScore: Double = 0
    private let candidateTTLSeconds: TimeInterval = 2.0

    /// Decide whether a candidate should surface, replace, or be dropped.
    func evaluate(
        candidateScore: Double,
        candidateAge: TimeInterval,
        questionDensity: Double,
        kbRelevance: Double
    ) -> ThrottleDecision {
        // Candidate too old — drop it
        guard candidateAge <= candidateTTLSeconds else {
            return .drop(reason: "Candidate expired (age: \(String(format: "%.1f", candidateAge))s)")
        }

        let burstScore = (questionDensity * 0.4) + (kbRelevance * 0.6)

        let softMinSpacing: TimeInterval
        let replacementDelta: Double

        if burstScore > 0.7 {
            softMinSpacing = 0
            replacementDelta = 0.05
        } else if burstScore > 0.5 {
            softMinSpacing = 4
            replacementDelta = 0.10
        } else {
            softMinSpacing = 12
            replacementDelta = 0.20
        }

        let timeSinceLastSuggestion: TimeInterval
        if let last = lastSuggestionTime {
            timeSinceLastSuggestion = Date.now.timeIntervalSince(last)
        } else {
            timeSinceLastSuggestion = .infinity
        }

        if timeSinceLastSuggestion >= softMinSpacing {
            return .surface
        }

        if candidateScore >= lastSuggestionScore + replacementDelta {
            return .replace
        }

        return .drop(reason: "Throttled (spacing: \(String(format: "%.0f", softMinSpacing))s, delta needed: \(String(format: "%.2f", replacementDelta)))")
    }

    /// Call after a suggestion is actually shown to the user.
    func recordSurfaced(score: Double) {
        lastSuggestionTime = .now
        lastSuggestionScore = score
    }

    func clear() {
        lastSuggestionTime = nil
        lastSuggestionScore = 0
    }

    enum ThrottleDecision {
        case surface
        case replace
        case drop(reason: String)

        var shouldShow: Bool {
            switch self {
            case .surface, .replace: true
            case .drop: false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/BurstDecayThrottle.swift
git commit -m "feat: add BurstDecayThrottle — drop-or-display pacing for suggestions"
```

---

### Task 8: SuggestionEngine Rewrite

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/SuggestionEngine.swift`

This is the core rewrite — replacing the 5-stage serial pipeline with the 3-layer concurrent architecture.

- [ ] **Step 1: Replace the entire file contents**

The new `SuggestionEngine` has three concurrent layers:
1. Periodic KB pre-fetcher (taps partial speech every N seconds)
2. Gate + retrieval on finalized utterances (from either speaker)
3. Streaming LLM synthesis

Implementation constraints for this task:

- Assume Task 3A is already complete; Layer 1 should consume real incremental hypotheses or the finalized-window fallback, not imaginary partial callbacks.
- Preserve compatibility shims needed by the rest of the app during rollout: a computed `[Suggestion]` projection for the mini bar/live state, an `isGenerating` alias if existing polling code still depends on it, and a per-trigger log snapshot API for `SessionRepository`.
- Every provider switch in this task must cover `.openRouter`, `.ollama`, `.mlx`, and `.openAICompatible`.
- Use the same provider URL construction rules as the current engine (`OpenRouterClient.chatCompletionsURL(from:)`), not hard-coded string concatenation.
- The background state tracker must use the active primary model for the current provider, not hard-code `selectedModel`.

```swift
import Foundation
import Observation

/// Real-time suggestion engine with 3-layer concurrent architecture.
///
/// Layer 1: Continuous context (pre-fetch KB on partial speech every N seconds)
/// Layer 2: Instant retrieval + local heuristic gate on finalized utterances
/// Layer 3: Streaming LLM synthesis
@Observable
@MainActor
final class SuggestionEngine {
    // MARK: - Observable State

    @ObservationIgnored nonisolated(unsafe) private var _activeSuggestions: [RealtimeSuggestion] = []
    private(set) var activeSuggestions: [RealtimeSuggestion] {
        get { access(keyPath: \.activeSuggestions); return _activeSuggestions }
        set { withMutation(keyPath: \.activeSuggestions) { _activeSuggestions = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isStreaming = false
    private(set) var isStreaming: Bool {
        get { access(keyPath: \.isStreaming); return _isStreaming }
        set { withMutation(keyPath: \.isStreaming) { _isStreaming = newValue } }
    }

    // MARK: - Dependencies

    private let client = OpenRouterClient()
    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings
    private let preFetchCache: PreFetchCache
    private let gate: RealtimeGate
    private let throttle = BurstDecayThrottle()

    // MARK: - Tasks

    private var preFetchTask: Task<Void, Never>?
    private var backgroundStateTask: Task<Void, Never>?
    private var synthesisTask: Task<Void, Never>?
    private var lastProcessedUtteranceID: UUID?

    /// Text snippets of the last 3 shown suggestions for duplicate suppression.
    private var recentSuggestionTexts: [String] = []

    private static let maxActiveSuggestions = 3

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
        self.preFetchCache = PreFetchCache(ttlSeconds: 30)
        self.gate = RealtimeGate(kbSimilarityThreshold: settings.kbSimilarityThreshold)
    }

    // MARK: - Layer 1: Continuous Context

    /// Start the periodic pre-fetch loop. Call when a session starts.
    func startPreFetching() {
        preFetchTask?.cancel()
        preFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.settings.preFetchIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self.runPreFetch()
            }
        }
    }

    private func runPreFetch() async {
        let queryText = transcriptStore.preFetchQueryText
        let words = queryText.split(separator: " ")
        guard words.count >= 5 else { return }  // Skip very short text

        let fingerprint = PreFetchCache.fingerprint(queryText)

        // Skip if we already have a recent result for similar text
        if await preFetchCache.get(fingerprint: fingerprint) != nil { return }

        let packs = await knowledgeBase.searchContextPacks(
            queries: [String(words.suffix(40).joined(separator: " "))],
            topK: 3
        )

        guard !packs.isEmpty else { return }
        await preFetchCache.store(fingerprint: fingerprint, packs: packs)

        // If a pre-fetch discovers a high-quality match, try to surface it
        let topScore = packs.first?.score ?? 0
        if topScore >= settings.kbSimilarityThreshold {
            let querySnippet = String(words.suffix(20).joined(separator: " "))
            tryGateAndSurface(
                text: querySnippet,
                speaker: nil,
                utteranceID: nil,
                cachedPacks: packs
            )
        }
    }

    // MARK: - Layer 1b: Background State Tracker

    /// Trigger a background conversation state update if needed.
    /// This runs the LLM state tracker asynchronously — never blocks suggestions.
    func triggerBackgroundStateUpdate() {
        guard transcriptStore.needsStateUpdateFromEitherSpeaker else { return }
        guard backgroundStateTask == nil else { return }  // Already running

        backgroundStateTask = Task { [weak self] in
            guard let self else { return }
            await self.updateConversationState()
            self.backgroundStateTask = nil
        }
    }

    private func updateConversationState() async {
        let recentUtterances = transcriptStore.recentExchange
        let previousState = transcriptStore.conversationState
        guard let latestUtterance = recentUtterances.last else { return }

        let statePrompt = buildConversationStatePrompt(
            previousState: previousState,
            recentUtterances: recentUtterances,
            latestUtterance: latestUtterance
        )

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: activePrimaryModel,
                messages: statePrompt,
                maxTokens: 512,
                baseURL: llmBaseURL(forRealtime: false)
            )

            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8) {
                let update = try JSONDecoder().decode(ConversationStateUpdate.self, from: data)
                let state = ConversationState(
                    currentTopic: update.currentTopic,
                    shortSummary: update.shortSummary,
                    openQuestions: update.openQuestions,
                    activeTensions: update.activeTensions,
                    recentDecisions: update.recentDecisions,
                    themGoals: update.themGoals,
                    suggestedAnglesRecentlyShown: previousState.suggestedAnglesRecentlyShown,
                    lastUpdatedAt: .now
                )
                transcriptStore.updateConversationState(state)
            }
        } catch {
            print("[SuggestionEngine] Background state update failed: \(error)")
        }
    }

    private struct ConversationStateUpdate: Codable {
        let currentTopic: String
        let shortSummary: String
        let openQuestions: [String]
        let activeTensions: [String]
        let recentDecisions: [String]
        let themGoals: [String]
    }

    // MARK: - Layer 2: Gate + Retrieval

    /// Called when any finalized utterance arrives (from either speaker).
    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        // Validate credentials
        switch settings.llmProvider {
        case .openRouter:
            guard !settings.openRouterApiKey.isEmpty else { return }
        case .ollama, .mlx, .openAICompatible:
            guard llmBaseURL(forRealtime: true) != nil else { return }
        }

        // Also trigger background state update
        triggerBackgroundStateUpdate()

        // Run gate and surface
        let text = utterance.text
        let speaker = utterance.speaker

        // Check pre-fetch cache first
        let fingerprint = PreFetchCache.fingerprint(text)

        Task {
            let cachedEntry = await preFetchCache.get(fingerprint: fingerprint)
            let packs: [KBContextPack]

            if let cached = cachedEntry {
                packs = cached.packs
            } else {
                // Fresh KB search
                packs = await knowledgeBase.searchContextPacks(
                    queries: [text],
                    topK: 3
                )
            }

            tryGateAndSurface(
                text: text,
                speaker: speaker,
                utteranceID: utterance.id,
                cachedPacks: packs
            )
        }
    }

    private func tryGateAndSurface(
        text: String,
        speaker: Speaker?,
        utteranceID: UUID?,
        cachedPacks: [KBContextPack]
    ) {
        guard !cachedPacks.isEmpty else { return }

        let gateResult = gate.evaluate(
            text: text,
            speaker: speaker ?? .them,
            contextPacks: cachedPacks,
            questionDensity: transcriptStore.questionDensity,
            recentSuggestionTexts: recentSuggestionTexts
        )

        guard gateResult.shouldSurface else { return }

        // Burst/decay throttle
        let kbRelevance = cachedPacks.first?.score ?? 0
        let throttleDecision = throttle.evaluate(
            candidateScore: gateResult.score,
            candidateAge: 0,  // Fresh candidate
            questionDensity: transcriptStore.questionDensity,
            kbRelevance: kbRelevance
        )

        guard throttleDecision.shouldShow else { return }

        // Surface it
        surfaceCandidate(
            triggerKind: gateResult.triggerKind,
            triggerExcerpt: String(text.prefix(100)),
            triggerUtteranceID: utteranceID,
            contextPacks: cachedPacks,
            score: gateResult.score
        )
    }

    // MARK: - Layer 3: Streaming Synthesis

    private func surfaceCandidate(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        triggerUtteranceID: UUID?,
        contextPacks: [KBContextPack],
        score: Double
    ) {
        // Mark any in-flight suggestion as superseded
        if let currentIdx = activeSuggestions.firstIndex(where: { $0.lifecycle == .streaming }) {
            activeSuggestions[currentIdx].lifecycle = .superseded
        }
        synthesisTask?.cancel()

        // Create the new suggestion in .raw state (instantly visible)
        var suggestion = RealtimeSuggestion(
            triggerKind: triggerKind,
            triggerExcerpt: triggerExcerpt,
            triggerUtteranceID: triggerUtteranceID,
            contextPacks: contextPacks,
            candidateScore: score
        )

        // Insert at front, trim to max
        activeSuggestions.insert(suggestion, at: 0)
        if activeSuggestions.count > Self.maxActiveSuggestions {
            activeSuggestions = Array(activeSuggestions.prefix(Self.maxActiveSuggestions))
        }

        // Track for duplicate suppression
        let snippetText = suggestion.rawSnippet
        recentSuggestionTexts.append(snippetText)
        if recentSuggestionTexts.count > 3 {
            recentSuggestionTexts.removeFirst()
        }

        // Record in throttle
        throttle.recordSurfaced(score: score)

        // Start streaming LLM synthesis
        let suggestionID = suggestion.id
        isStreaming = true

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            await self.streamSynthesis(
                suggestionID: suggestionID,
                triggerKind: triggerKind,
                triggerExcerpt: triggerExcerpt,
                contextPacks: contextPacks
            )
            self.isStreaming = false
        }
    }

    private func streamSynthesis(
        suggestionID: UUID,
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        contextPacks: [KBContextPack]
    ) async {
        guard let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        activeSuggestions[idx].lifecycle = .streaming

        let messages = buildSynthesisPrompt(
            triggerKind: triggerKind,
            triggerExcerpt: triggerExcerpt,
            contextPacks: contextPacks
        )

        do {
            let stream = await client.streamCompletion(
                apiKey: llmApiKey,
                model: settings.activeRealtimeModel,
                messages: messages,
                maxTokens: 200,
                baseURL: llmBaseURL(forRealtime: true)
            )

            var accumulated = ""
            for try await chunk in stream {
                guard !Task.isCancelled else { break }
                accumulated += chunk
                if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                    activeSuggestions[idx].synthesizedText = accumulated
                }
            }

            if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                activeSuggestions[idx].lifecycle = Task.isCancelled ? .superseded : .completed
            }
        } catch {
            print("[SuggestionEngine] Synthesis stream error: \(error)")
            if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                activeSuggestions[idx].lifecycle = .failed
            }
        }
    }

    // MARK: - Lifecycle

    func clear() {
        preFetchTask?.cancel()
        backgroundStateTask?.cancel()
        synthesisTask?.cancel()
        preFetchTask = nil
        backgroundStateTask = nil
        synthesisTask = nil
        activeSuggestions.removeAll()
        isStreaming = false
        lastProcessedUtteranceID = nil
        recentSuggestionTexts.removeAll()
        throttle.clear()
        Task { await preFetchCache.clear() }
    }

    func stopPreFetching() {
        preFetchTask?.cancel()
        preFetchTask = nil
    }

    // MARK: - LLM Helpers

    private var activePrimaryModel: String {
        switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .ollama: nil
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    private func llmBaseURL(forRealtime: Bool) -> URL? {
        switch settings.llmProvider {
        case .openRouter: return nil  // Uses default OpenRouter URL
        case .ollama:
            return OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .mlx:
            return OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            return OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }

    // MARK: - Prompts

    private func buildConversationStatePrompt(
        previousState: ConversationState,
        recentUtterances: [Utterance],
        latestUtterance: Utterance
    ) -> [OpenRouterClient.Message] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let prevJSON = (try? String(data: encoder.encode(previousState), encoding: .utf8)) ?? "{}"

        var conversationText = ""
        for u in recentUtterances {
            let label = u.speaker == .you ? "You" : "Them"
            conversationText += "\(label): \(u.text)\n"
        }

        let system = """
        You are a conversation state tracker for a real-time meeting assistant. \
        Update the meeting state based on new utterances. Output compact JSON only, no prose.

        Rules:
        - 2-4 sentence summary max
        - Prefer unresolved questions over historical detail
        - Prefer what "them" appears to want or optimize for
        - Keep all arrays short (max 3-4 items each)
        - Output only valid JSON matching this schema:
        {"currentTopic":"string","shortSummary":"string","openQuestions":["string"],"activeTensions":["string"],"recentDecisions":["string"],"themGoals":["string"]}
        """

        let user = """
        Previous state:
        \(prevJSON)

        Recent conversation:
        \(conversationText)
        Latest utterance (\(latestUtterance.speaker == .you ? "You" : "Them")): \(latestUtterance.text)

        Output the updated conversation state as JSON:
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func buildSynthesisPrompt(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        contextPacks: [KBContextPack]
    ) -> [OpenRouterClient.Message] {
        let state = transcriptStore.conversationState

        var evidenceText = ""
        for pack in contextPacks.prefix(3) {
            evidenceText += "[\(pack.displayBreadcrumb)]:\n\(pack.matchedText)\n"
            if let prev = pack.previousSiblingText {
                evidenceText += "(preceding context: \(prev.prefix(200)))\n"
            }
            evidenceText += "\n"
        }

        let formatInstruction: String
        switch triggerKind {
        case .question:
            formatInstruction = "Suggest a specific answer or data point the user can reference."
        case .claim:
            formatInstruction = "Surface supporting or contradicting evidence from the KB."
        case .topic:
            formatInstruction = "Surface the most relevant related context from the KB."
        case .general:
            formatInstruction = "Briefly explain why this KB context is relevant right now."
        }

        let system = """
        You are a real-time meeting copilot. Generate a BRIEF, immediately useful insight \
        grounded in the retrieved evidence. One to three sentences max. No bullet points, \
        no hedging, no filler. \(formatInstruction)
        """

        let user = """
        Trigger: \(triggerExcerpt)

        Conversation context: \(state.shortSummary.isEmpty ? "N/A" : state.shortSummary)

        Evidence:
        \(evidenceText)
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (or fix any compilation errors)

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/SuggestionEngine.swift
git commit -m "feat: rewrite SuggestionEngine with 3-layer concurrent architecture

Replaces 5-stage serial pipeline (3 LLM calls, 90s cooldown) with:
- Layer 1: periodic KB pre-fetch on partial speech
- Layer 2: local heuristic gate on finalized utterances
- Layer 3: streaming LLM synthesis with fast model

Both speakers analyzed. Sub-2-second target latency."
```

---

### Task 9: SessionRepository Suggestion Identity Persistence

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Storage/SessionRepository.swift`
- Modify: `OpenOats/Sources/OpenOats/Intelligence/SuggestionEngine.swift`
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

The delayed live-write path must log the suggestion triggered by a specific utterance, not whichever suggestion happens to be newest five seconds later.

- [ ] **Step 1: Add a per-trigger log snapshot API to `SuggestionEngine`**

Implementation rules:

- Maintain a short-lived non-UI lookup keyed by `triggerUtteranceID`.
- Store enough data to write a `SessionRecord`: `suggestionID`, `triggerUtteranceID`, lifecycle, surfaced text, and KB hit paths.
- Keep snapshots alive long enough for delayed writes even after a suggestion is superseded or falls out of `activeSuggestions`.
- Expose a method such as `logSnapshot(forTriggerUtteranceID:)`.

- [ ] **Step 2: Update `SessionRepository.appendRecordDelayed`**

Implementation rules:

- Patch `SessionRepository.swift`, not the removed `SessionStore.swift`.
- Replace any `lastDecision`, `suggestions.first`, or `activeSuggestions.first` lookup with `logSnapshot(forTriggerUtteranceID: utteranceID)`.
- Populate the new `SessionRecord` identity fields from that snapshot.
- Keep human-readable fields like `surfacedSuggestionText` and `kbHits`, but make them derived from the matched snapshot rather than the latest suggestion overall.

- [ ] **Step 3: Route delayed writes through both-speaker triggers**

Implementation rules:

- In `LiveSessionController.handleNewUtterance`, any finalized utterance that can trigger suggestions should be written with delayed metadata (`utteranceID`, `suggestionEngine`, `transcriptStore`, `isDelayed: true`).
- Do not keep the old remote-only delayed-write split now that `.you` utterances can also surface suggestions.

- [ ] **Step 4: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Storage/SessionRepository.swift OpenOats/Sources/OpenOats/Intelligence/SuggestionEngine.swift OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "fix: persist realtime suggestions by trigger identity in SessionRepository"
```

---

### Task 10: Suggestion Panel (Floating Side Panel)

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/OverlayPanel.swift`

- [ ] **Step 1: Extend OverlayManager for side-panel mode**

Replace the entire `OverlayManager` class (keep the `OverlayPanel` class unchanged):

```swift
/// Manages the floating suggestion side panel lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    private var panel: OverlayPanel?
    var defaults: UserDefaults = .standard
    private static let panelWidth: CGFloat = 250
    private static let panelMinHeight: CGFloat = 100
    private static let panelMaxHeight: CGFloat = 400

    func showSidePanel<Content: View>(content: Content) {
        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            // Dock to right edge of screen
            let rect = NSRect(
                x: screenFrame.maxX - Self.panelWidth - 12,
                y: screenFrame.midY - Self.panelMaxHeight / 2,
                width: Self.panelWidth,
                height: Self.panelMaxHeight
            )
            let newPanel = OverlayPanel(contentRect: rect, defaults: defaults)
            newPanel.minSize = NSSize(width: Self.panelWidth, height: Self.panelMinHeight)
            newPanel.maxSize = NSSize(width: Self.panelWidth + 100, height: Self.panelMaxHeight)
            newPanel.setFrameAutosaveName("SuggestionSidePanel")
            panel = newPanel
        }

        let hostingView = NSHostingView(rootView: content)
        panel?.contentView = hostingView
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle<Content: View>(content: Content) {
        if panel?.isVisible == true {
            hide()
        } else {
            showSidePanel(content: content)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// Hide after a delay (used for session end).
    func hideAfterDelay(seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            hide()
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/OverlayPanel.swift
git commit -m "feat: extend OverlayManager for side-panel mode (250px, docked right)"
```

---

### Task 11: SuggestionPanelContent View

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/SuggestionPanelContent.swift`

- [ ] **Step 1: Create the panel content view**

```swift
import SwiftUI

/// Content view for the floating suggestion side panel.
/// Shows the current suggestion (raw or streaming) with fading previous suggestions.
struct SuggestionPanelContent: View {
    let suggestions: [RealtimeSuggestion]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(isStreaming ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text("OpenOats")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if suggestions.isEmpty {
                idleView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            SuggestionPanelCard(
                                suggestion: suggestion,
                                isPrimary: index == 0,
                                fadeFraction: fadeFraction(for: index)
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var idleView: some View {
        VStack(spacing: 6) {
            Text("Listening...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opacity fraction for suggestion at the given index.
    /// Index 0 = 1.0, index 1 = 0.6, index 2 = 0.3
    private func fadeFraction(for index: Int) -> Double {
        switch index {
        case 0: 1.0
        case 1: 0.6
        default: 0.3
        }
    }
}

// MARK: - Card

private struct SuggestionPanelCard: View {
    let suggestion: RealtimeSuggestion
    let isPrimary: Bool
    let fadeFraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Source breadcrumb
            if !suggestion.sourceBreadcrumb.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 8))
                    Text(suggestion.sourceBreadcrumb)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }

            // Main text (raw snippet or streamed synthesis)
            Text(suggestion.displayText)
                .font(.system(size: isPrimary ? 12 : 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            // Streaming indicator
            if suggestion.lifecycle == .streaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Synthesizing...")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            // Score badge (subtle)
            if isPrimary, let topPack = suggestion.contextPacks.first {
                Text(String(format: "%.0f%% match", topPack.score * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPrimary ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(fadeFraction)
        .animation(.easeOut(duration: 0.3), value: fadeFraction)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SuggestionPanelContent.swift
git commit -m "feat: add SuggestionPanelContent view for floating side panel"
```

---

### Task 12: LiveSessionController + ContentView Integration

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/ContentView.swift`

`ContentView` now mostly wraps controller behavior; the real session lifecycle and utterance ingestion live in `LiveSessionController`. Wire the suggestion panel through the controller instead of patching stale view-only entry points.

- [ ] **Step 1: Remove the inline `SuggestionsView` from `ContentView`**

Replace the main inline suggestions area with a compact status row that points users to the floating panel.

Implementation rules:

- Read from the controller-driven state or `coordinator.suggestionEngine`, not from an undeclared local `suggestionEngine`.
- Keep the transcript and control-bar layout intact.

- [ ] **Step 2: Extend controller wiring in `ContentView.task`**

Implementation rules:

- Keep the existing mini-bar behavior.
- When `onRunningStateChanged(true)` fires, start pre-fetching and show the suggestion panel if `settings.suggestionPanelEnabled` is true.
- When `onRunningStateChanged(false)` fires, stop pre-fetching and hide the panel after roughly 2 seconds.
- Add an `onSuggestionPanelContentUpdate` callback analogous to `onMiniBarContentUpdate`.

- [ ] **Step 3: Update `LiveSessionController` state synchronization**

Implementation rules:

- Observe realtime suggestion IDs and streaming state from `coordinator.suggestionEngine`.
- Fire `onSuggestionPanelContentUpdate` when those values change.
- If the mini bar still depends on `[Suggestion]` / `isGeneratingSuggestions`, populate those from the compatibility projection exposed by `SuggestionEngine`.

- [ ] **Step 4: Update `LiveSessionController.handleNewUtterance`**

Implementation rules:

- Call `coordinator.suggestionEngine?.onUtterance(last)` for finalized utterances from either speaker.
- Keep refinement and meeting-detection behavior unchanged.
- Use delayed session-write metadata for both speakers as described in Task 9.

- [ ] **Step 5: Add panel helper methods in `ContentView`**

Implementation rules:

- Build panel content from `coordinator.suggestionEngine?.activeSuggestions` and `.isStreaming`.
- `toggleOverlay()` should toggle the side panel, not recreate the removed `OverlayContent`.
- Avoid direct session-start/session-stop mutations in `ContentView` beyond calling the controller wrappers.

- [ ] **Step 6: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "feat: integrate realtime suggestion panel through LiveSessionController"
```

---

### Task 13: Settings View Updates

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

- [ ] **Step 1: Add Real-Time Suggestions section**

Add after the "LLM Provider" section:

```swift
            Section("Real-Time Suggestions") {
                Toggle("Floating suggestion panel", isOn: $settings.suggestionPanelEnabled)
                    .font(.system(size: 12))
                Text("Show a floating side panel with real-time KB-backed suggestions during meetings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                switch settings.llmProvider {
                case .openRouter:
                    TextField("Speed Model", text: $settings.realtimeModel, prompt: Text("e.g. google/gemini-2.0-flash-001"))
                        .font(.system(size: 12, design: .monospaced))
                    Text("A fast model used for real-time suggestion synthesis. Separate from your main model.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .ollama:
                    TextField("Speed Model", text: $settings.realtimeOllamaModel, prompt: Text("Leave empty to use main model"))
                        .font(.system(size: 12, design: .monospaced))
                    Text("Optional Ollama model for real-time suggestions. Uses your main model if empty.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .mlx, .openAICompatible:
                    Text("Real-time suggestions currently reuse the active provider model for this provider.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: add real-time suggestion settings to SettingsView"
```

---

### Task 14: Panel Hotkey

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/ContentView.swift`

- [ ] **Step 1: Extend the existing hotkey infrastructure**

Reuse the existing global/local hotkey monitor flow in `AppDelegate` rather than adding a command-only shortcut.

Implementation rules:

- Add a second matcher for `Cmd+Shift+O` alongside the existing meeting toggle hotkey.
- Ensure both the global and local monitors trigger the same panel-toggle path.
- Keep the scene command keyboard shortcut aligned with the same key so the shortcut works when the app is focused too.

- [ ] **Step 2: Add a lightweight toggle signal**

Use the same signal path for both hotkey monitors and the focused-app command shortcut. A `Notification.Name.toggleSuggestionPanel` helper is acceptable if you want to keep the wiring lightweight.

- [ ] **Step 3: Handle the toggle in `ContentView`**

Add the matching receiver to `contentWithEventHandlers` and route it to `toggleOverlay()`.

```swift
        .onReceive(NotificationCenter.default.publisher(for: .toggleSuggestionPanel)) { _ in
            toggleOverlay()
        }
```

- [ ] **Step 4: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/OpenOatsApp.swift OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "feat: add Cmd+Shift+O hotkey to toggle the realtime suggestion panel"
```

---

### Task 15: Cleanup — Remove Unused Files

**Files:**
- Delete: `OpenOats/Sources/OpenOats/Views/OverlayContent.swift`
- Delete: `OpenOats/Sources/OpenOats/Views/SuggestionsView.swift`

- [ ] **Step 1: Verify no remaining references to `OverlayContent`**

Search for `OverlayContent` in the codebase. The only reference should have been in `ContentView.toggleOverlay()` which was updated in Task 12.

Run: `grep -r "OverlayContent" OpenOats/Sources/`
Expected: No results (or only the file itself)

- [ ] **Step 2: Verify no remaining references to `SuggestionsView`**

Run: `grep -r "SuggestionsView" OpenOats/Sources/`
Expected: No results (or only the file itself)

- [ ] **Step 3: Delete the files**

```bash
rm OpenOats/Sources/OpenOats/Views/OverlayContent.swift
rm OpenOats/Sources/OpenOats/Views/SuggestionsView.swift
```

- [ ] **Step 4: Build to verify**

Run: `cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add -u OpenOats/Sources/OpenOats/Views/OverlayContent.swift OpenOats/Sources/OpenOats/Views/SuggestionsView.swift
git commit -m "chore: remove unused OverlayContent and SuggestionsView (replaced by SuggestionPanelContent)"
```

---

### Task 16: Full Build Verification

- [ ] **Step 1: Clean build**

```bash
cd /Users/rock/ai/projects/openoats/OpenOats && swift package clean && swift build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED with no errors.

- [ ] **Step 2: Check for compiler warnings**

```bash
cd /Users/rock/ai/projects/openoats/OpenOats && swift build 2>&1 | grep -i warning | head -20
```

Fix any warnings related to our changes.

- [ ] **Step 3: Verify the release build**

```bash
cd /Users/rock/ai/projects/openoats && ./scripts/build_swift_app.sh 2>&1 | tail -10
```

Expected: Builds, code-signs, and installs to `/Applications/OpenOats.app`

- [ ] **Step 4: Final commit (if any fixes were needed)**

```bash
git add -A
git commit -m "fix: resolve build warnings from real-time suggestion engine"
```

---

## Verification Checklist

After all tasks are complete, manually verify:

1. **App launches** without crashes
2. **Session start** shows the floating side panel on the right edge
3. **Panel is invisible** in screenshot/screen recording (open QuickTime, start screen recording preview — panel should not appear)
4. **Cmd+Shift+O** toggles the panel
5. **With a KB folder configured**, speaking triggers KB-backed suggestions in the panel
6. **Suggestions show source breadcrumbs** like `folder/file.md > Heading`
7. **LLM synthesis streams** into the panel (text appears progressively)
8. **Previous suggestions fade** as new ones arrive
9. **Session stop** hides the panel after ~2 seconds
10. **Settings** show the new "Real-Time Suggestions" section with speed model picker
