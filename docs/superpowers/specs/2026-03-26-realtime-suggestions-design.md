# Real-Time Suggestion Engine Redesign

**Date:** 2026-03-26
**Status:** Draft
**Branch:** TBD (worktree)

## Problem

The current suggestion pipeline has 5 serial stages with 3 LLM round-trips, a 90-second cooldown, and only triggers on finalized "them" utterances. End-to-end latency is 5-10+ seconds. For a real-time meeting copilot, suggestions need to appear within 1-2 seconds of a relevant conversational moment.

## Design Goals

1. **Sub-2-second suggestion latency** from conversational trigger to visible suggestion
2. **Continuous context accumulation** — system always knows what the conversation is about
3. **Both speakers analyzed** — your speech and their speech both contribute context and trigger suggestions
4. **Minimal distraction** — smart throttling so suggestions only appear when genuinely useful
5. **Context-rich retrieval** — retrieved evidence preserves file, folder, heading, and neighboring-section context so snippets are interpretable

## Architecture Overview

Replace the 5-stage serial pipeline with a 3-layer concurrent architecture:

```
Layer 1: Continuous Context   (always running, never blocks)
Layer 2: Instant Retrieval    (triggered by context changes)
Layer 3: Streaming Synthesis  (triggered by retrieval results)
```

**Implementation constraint:** Sub-2-second latency requires incremental transcript emission from the transcription stack. Exposing partial hypotheses from the existing transcriber is explicitly in scope for this redesign.

### Layer 1: Continuous Context Accumulator

**Purpose:** Maintain a real-time understanding of the conversation without blocking suggestions.

**Components:**
- **Incremental Transcript Buffer:** Collects partial/in-progress transcription text from both speakers (mic + system audio) when the backend supports it, and falls back to a rolling window of the most recent finalized utterances when it does not. This redesign explicitly extends the existing transcriber path to emit partial hypotheses at roughly 250-500ms cadence instead of finals-only.
- **Periodic KB Pre-Fetcher:** Every 2-4 seconds, takes the latest incremental buffer and/or recent finalized window (~40-80 words with speaker labels), runs a KB search, and stores `KBContextPack` results in a `PreFetchCache` keyed by a normalized text fingerprint.
- **Background State Tracker:** An async LLM call (using the user's main model) that updates the `ConversationState` struct every 2-3 finalized utterances from either speaker. It writes to shared state that other layers read but never wait on.

**Key property:** Nothing in Layer 1 blocks suggestion delivery. All work is speculative/background.

### Layer 2: Instant Retrieval & Gating

**Purpose:** When a conversational moment warrants a suggestion, retrieve relevant KB context instantly.

**Trigger:** When a new utterance is finalized (from either speaker), or when the periodic pre-fetcher detects a significant KB match for the active rolling window (top score crosses threshold or improves materially over the last pre-fetch hit).

**Pipeline (local gate + cached retrieval; target <100ms on cache hit):**

1. **Local Heuristic Gate** — replaces the LLM surfacing gate:
   - Question detection (same keyword/punctuation heuristics as today's `detectTrigger`)
   - KB similarity score check (top result > configurable threshold, default 0.35)
   - Conversation momentum score: combine question density (questions in last 60s) + KB match quality
   - Burst/decay pacing: if both signals are strong, allow rapid replacements. If neither, suppress.
   - Duplicate suppression: Jaccard similarity against last 3 shown suggestions
   - Freshness TTL: suggestions must surface immediately or be dropped; no delayed queue of stale candidates

2. **KB Result Selection** — if the pre-fetcher already has cached results for recent text, use them immediately (0ms). Otherwise, run a synchronous KB search on the finalized utterance text (~100-200ms for local embeddings, ~200-500ms for API). Retrieval returns `KBContextPack`s, not bare chunks.

3. **Output:** A `RealtimeSuggestionCandidate` containing:
   - A stable `candidateID`
   - The triggering utterance ID or active pre-fetch fingerprint
   - The top 1-3 `KBContextPack`s
   - The trigger type (question, claim, topic_shift, exploration)
   - The triggering text excerpt
   - Candidate score + creation timestamp

### KB Context Packaging

Raw chunk text is not enough. Retrieval must preserve document structure so the surfaced context is intelligible and actionable.

- Each `KBContextPack` includes: matched chunk text, relative file path, folder breadcrumb, document title, header breadcrumb, score, and one adjacent sibling chunk before/after when available.
- Embeddings should include document metadata (`folder path + file name + heading breadcrumb + body text`) so ranking benefits from structure instead of relying on body text alone.
- Chunking should stay section-aware: keep short sibling paragraphs/bullets together, preserve heading ancestry, and only split large sections with overlap.
- The UI and synthesis prompt should receive the full context pack. The breadcrumb shown to the user should look like `sales/pricing.md > Pricing > Unit Economics`, not only `pricing.md`.

### Layer 3: Streaming Synthesis

**Purpose:** Enhance raw KB results with LLM-generated contextual insight, streamed to the UI.

**Model:** A separate "speed model" setting (`settings.realtimeModel`). Defaults to a fast model (e.g., `google/gemini-2.0-flash-001` on OpenRouter). For Ollama, uses whatever the user configures.

**Pipeline:**

1. Allocate a stable `suggestionID` and create a `SuggestionState` in `.raw` status as soon as the candidate passes Layer 2.
2. Immediately surface the raw KB context pack(s) in the UI (instant, <200ms from trigger)
3. Fire an async streaming LLM call with:
   - The triggering utterance text
   - The matched `KBContextPack`s as context
   - The current conversation state (whatever's available from background tracker)
   - Adaptive format instruction based on trigger type (collapsed from the current 8 trigger kinds):
     - `question` (maps from: explicitQuestion, decisionPoint) → "Suggest a specific answer or data point the user can reference"
     - `claim` (maps from: assumption, disagreement) → "Surface supporting or contradicting evidence from the KB"
     - `topic` (maps from: customerProblem, distributionGoToMarket, productScope, prioritization) → "Surface the most relevant related context from the KB"
     - `general` (fallback) → "Briefly explain why this KB context is relevant right now"
4. Stream the LLM response token-by-token into the existing `SuggestionState` by `suggestionID`, replacing/enhancing the raw KB snippet in place
5. If the LLM call fails or is cancelled (new suggestion supersedes), the raw KB snippet remains and the suggestion status becomes `.failed` or `.superseded`

**Cancellation:** If a new suggestion candidate arrives while synthesis is streaming, compare freshness + score. If the new candidate wins, mark the in-flight suggestion `.superseded`, preserve its stable ID for history/logging, and start a new `suggestionID`. The old suggestion fades (see UI section).

### Suggestion Identity & Persistence

- `suggestionID` is stable across the raw → streaming → completed/failed/superseded lifecycle.
- `triggerUtteranceID` links each surfaced suggestion to the finalized utterance or pre-fetch fingerprint that caused it.
- Session logging persists `suggestionID`, `triggerUtteranceID`, and lifecycle status so delayed writes cannot accidentally attach the wrong suggestion to the wrong utterance.

## UI: Floating Side Panel

### Window Properties

- **Type:** `NSPanel` with `.nonactivatingPanel` style mask — stays on top without stealing focus
- **Sharing:** `sharingType = .none` — invisible to screen capture/sharing by default. Togglable in settings.
- **Size:** ~250px wide, height adapts to content (min 100px, max 400px)
- **Position:** Docked to right edge of screen by default, draggable to any edge
- **Appearance:** `.ultraThinMaterial` background, matches system appearance

### Content Layout

```
+----------------------------------+
|  [Source: sales/pricing.md >     |  <- KB source breadcrumb (muted)
|   Pricing > Unit Economics]      |
|                                  |
|  Their CAC concern — your notes  |  <- LLM synthesis (streams in)
|  show 3 channels under $50 CAC  |
|  (referral, organic, community)  |
|                                  |
+----------------------------------+
|  [Pricing > Unit Economics]  0.82|  <- Previous suggestion (fading)
|  Gross margin benchmarks...      |
+----------------------------------+
```

- **Current suggestion:** Full display with relative-path + heading breadcrumb, synthesized text (or raw KB snippet while LLM streams), and optional adjacent-context disclosure if the match needs neighboring text to make sense
- **Previous suggestions:** Up to 2 previous suggestions shown below, progressively faded (opacity 0.6 → 0.3 over 5 seconds)
- **Fade behavior:** When a new suggestion arrives, current becomes previous. Previous suggestions fade over 3-5 seconds. After 5 seconds at minimum opacity, they're removed.

### Visual States

- **Idle:** Panel shows "Listening..." in muted text when no suggestions are active
- **Pre-fetching:** Subtle pulse/glow on the panel border when KB pre-fetch finds relevant results (primes the user that context is available)
- **Streaming:** Text appears token-by-token in the current suggestion slot
- **Fading:** Old suggestions animate opacity down

### Hotkey

- Global hotkey to show/hide the panel (default: `Cmd+Shift+O`, configurable)
- The panel auto-shows when a session starts and auto-hides when it ends

### Lifecycle Integration

- `ContentView.startSession()` → show panel (if `suggestionPanelEnabled`)
- `ContentView.stopSession()` → hide panel after a 2-second delay (lets user see final suggestion)
- Panel visibility persists across app focus changes (it's always-on-top)
- If the user closes the panel manually (hotkey or close button), it stays hidden until the next session or hotkey toggle

## Burst/Decay Throttling

The throttling system replaces the fixed 90-second cooldown with immediate drop-or-display pacing. Suggestions are never queued to surface long after the triggering moment.

### Signals

1. **Question density:** Count of utterances containing question markers (?, "what", "how", "why", etc.) in the last 60 seconds, from either speaker
2. **KB match quality:** Highest similarity score from the most recent KB search

### Logic

```
questionDensity = questionsInLast60s / totalUtterancesInLast60s
kbRelevance = topKBScore  // 0.0 - 1.0

burstScore = (questionDensity * 0.4) + (kbRelevance * 0.6)

if burstScore > 0.7:
    softMinSpacing = 0s
    replacementDelta = 0.05
elif burstScore > 0.5:
    softMinSpacing = 4s
    replacementDelta = 0.10
else:
    softMinSpacing = 12s
    replacementDelta = 0.20

candidateTTL = 2s

if timeSinceLastSuggestion >= softMinSpacing:
    surfaceImmediately()
elif candidateAge <= candidateTTL and candidateScore >= currentSuggestionScore + replacementDelta:
    replaceImmediately()
else:
    dropCandidate()
```

There is no delayed queue. Candidates either surface immediately, replace the currently shown suggestion while still fresh, or get dropped. Any candidate older than `candidateTTL` is discarded rather than shown late.

## Settings Changes

### New Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `realtimeModel` | String | `google/gemini-2.0-flash-001` | Model for real-time suggestion synthesis |
| `realtimeOllamaModel` | String | (empty) | Ollama model for real-time suggestions (if using Ollama) |
| `suggestionPanelEnabled` | Bool | true | Show the floating suggestion panel |
| `suggestionPanelPosition` | Enum | .right | Panel docking position (left/right) |
| `suggestionPanelHotkey` | String | `cmd+shift+o` | Toggle panel visibility |
| `hideFromScreenShare` | Bool | true | Hide panel from screen capture |
| `preFetchIntervalSeconds` | Double | 4.0 | KB pre-fetch interval on partial speech |
| `kbSimilarityThreshold` | Double | 0.35 | Minimum KB score to trigger suggestion |

### Removed/Replaced Settings

The following become internal constants (not user-facing):
- `cooldownSeconds` (90s) → replaced by burst/decay pacing
- Surfacing gate thresholds (relevanceScore, helpfulnessScore, timingScore, noveltyScore, confidenceScore) → replaced by local heuristic gate
- `candidateFreshnessTTLSeconds` → stale candidates are dropped instead of queued
- `contextNeighborChunkCount` → controls how much sibling context is bundled into a `KBContextPack`

### Preserved Settings

All existing settings remain: LLM provider, main model, embedding provider, KB folder path, API keys, transcription settings, etc.

## Data Flow Summary

```
Mic Audio ─┐
            ├─→ TranscriptionEngine ─→ incremental transcript buffer ─→ PreFetchCache (every 2-4s)
System Audio┘                        → finalized utterances
                                                 │
                                                 ├─→ Background State Tracker (async LLM)
                                                 │
                                                 ├─→ Local Heuristic Gate
                                                 │       │
                                                 │       ├─ (pass) → KB Retrieval (cached or fresh)
                                                 │       │               │
                                                 │       │               ├─→ `RealtimeSuggestionCandidate`
                                                 │       │               │         │
                                                 │       │               │         ├─→ `SuggestionState(.raw)` → panel
                                                 │       │               │         └─→ Async stream → same `suggestionID`
                                                 │       │
                                                 │       └─ (fail) → drop candidate
                                                 │
                                                 └─→ Burst/Decay tracker (drop-or-display pacing)
```

## Key Files to Modify

| File | Change |
|------|--------|
| `OpenOats/Sources/OpenOats/Intelligence/SuggestionEngine.swift` | **Rewrite.** New 3-layer architecture, stable suggestion identity, and drop-or-display pacing replace the 5-stage pipeline. |
| `OpenOats/Sources/OpenOats/Intelligence/OpenRouterClient.swift` | Minor: ensure streaming works cleanly with the fast model and cancellation semantics. |
| `OpenOats/Sources/OpenOats/Intelligence/KnowledgeBase.swift` | Add `searchCached()`/context-pack retrieval, preserve relative paths + folder structure, and bundle adjacent section context. |
| `OpenOats/Sources/OpenOats/Models/Models.swift` | Add `RealtimeSuggestionCandidate`, `KBContextPack`, `SuggestionState`, and stable suggestion lifecycle fields. |
| `OpenOats/Sources/OpenOats/Models/TranscriptStore.swift` | Expose incremental/finalized windows for both speakers. Add question-density tracking and rolling windows for pre-fetching. |
| `OpenOats/Sources/OpenOats/Transcription/StreamingTranscriber.swift` | Emit partial hypotheses instead of finals-only callbacks. |
| `OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift` | Plumb mic + system-audio partial callbacks into the transcript store. |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | Trigger suggestions from either speaker, manage panel lifecycle, and keep live state keyed by `suggestionID`. |
| `OpenOats/Sources/OpenOats/Storage/SessionRepository.swift` | Persist `suggestionID`, `triggerUtteranceID`, and lifecycle status so delayed writes remain correct. |
| `OpenOats/Sources/OpenOats/Views/SuggestionsView.swift` | **Rewrite** for streaming display with fade animation and richer source breadcrumbs. |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Remove inline suggestions section. Wire up floating panel. |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add new settings (realtimeModel, panel position, etc.) and replace cooldown-based configuration. |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Expose new panel + realtime settings. |
| `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` | Add configurable global hotkey support for showing/hiding the panel. |
| **New:** `OpenOats/Sources/OpenOats/Views/SuggestionPanel.swift` | Floating NSPanel with always-on-top, screen-share-invisible behavior. |
| **New:** `OpenOats/Sources/OpenOats/Intelligence/PreFetchCache.swift` | Caches recent KB search results keyed by text fingerprint. |
| **New:** `OpenOats/Sources/OpenOats/Intelligence/BurstDecayThrottle.swift` | Drop-or-display pacing logic. |
| **New:** `OpenOats/Sources/OpenOats/Intelligence/RealtimeGate.swift` | Local heuristic gate (replaces LLM surfacing gate). |

## Non-Goals

- Expanding KB file types beyond .md/.txt
- Changing the underlying audio capture pipeline, permissions model, or recording format beyond exposing incremental transcript callbacks
- Modifying the notes generation system
- Multi-language support changes

## Risks

1. **Pre-fetch cost:** ~10-20 embedding API calls/minute with Voyage AI. At $0.0001/call, negligible (~$0.12/hour). Monitor anyway.
2. **False positives:** Without the LLM gate, more noisy suggestions may surface. Mitigated by burst/decay throttling and KB similarity threshold.
3. **Floating panel UX:** Always-on-top panels can be annoying. Mitigated by hotkey toggle, auto-hide on session end, and configurable position.
4. **Partial speech noise:** Pre-fetching on incomplete sentences may produce irrelevant results. Mitigated by text fingerprint dedup and minimum word count before pre-fetching.
5. **Context pack size:** Including folder/file/header/sibling context increases embedding and prompt size. Mitigated by fixed-size context packs and adjacent-context limits.
6. **Lifecycle complexity:** Stable suggestion identity adds state transitions (`raw`, `streaming`, `completed`, `failed`, `superseded`). Mitigated by treating `suggestionID` as the single source of truth across UI + persistence.
