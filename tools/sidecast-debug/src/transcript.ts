import type { TranscriptSegment, AppSettings } from "./types.ts";

export async function fetchTranscript(
  videoId: string
): Promise<TranscriptSegment[]> {
  const res = await fetch(`/api/transcript?v=${videoId}`);
  if (!res.ok) {
    const err = await res.json();
    throw new Error(err.error || "Failed to fetch transcript");
  }
  const data = await res.json();
  return data.segments;
}

export function getSegmentsUpTo(
  segments: TranscriptSegment[],
  timestamp: number
): TranscriptSegment[] {
  return segments.filter((s) => s.start <= timestamp);
}

export function findActiveSegmentIndex(
  segments: TranscriptSegment[],
  timestamp: number
): number {
  for (let i = segments.length - 1; i >= 0; i--) {
    if (segments[i].start <= timestamp) return i;
  }
  return -1;
}

export interface ContextWindow {
  latestUtterance: string;
  recentExchange: string;
  widerContext: string;
  conversationSummary: string;
}

let runningSummary = "";
let segmentsSinceLastSummary = 0;
let lastSummarizedIndex = -1;

export function resetSummary(): void {
  runningSummary = "";
  segmentsSinceLastSummary = 0;
  lastSummarizedIndex = -1;
}

export function buildContextWindow(
  segments: TranscriptSegment[],
  currentTime: number,
  settings: AppSettings
): ContextWindow {
  const available = getSegmentsUpTo(segments, currentTime);
  if (available.length === 0) {
    return {
      latestUtterance: "",
      recentExchange: "",
      widerContext: "",
      conversationSummary: "No structured state yet.",
    };
  }

  const latest = available[available.length - 1];
  const recentCount = Math.min(5, available.length);
  const recentExchange = available
    .slice(-recentCount)
    .map((s) => `Speaker: ${s.text}`)
    .join("\n");

  let widerContext: string;
  let summary = "No structured state yet.";

  switch (settings.contextMode) {
    case "full": {
      const fullText = available.map((s) => `Speaker: ${s.text}`).join("\n");
      // Truncate to char limit
      widerContext =
        fullText.length > settings.fullModeCharLimit
          ? "..." + fullText.slice(-settings.fullModeCharLimit)
          : fullText;
      break;
    }
    case "window": {
      const windowSegs = available.slice(-settings.windowSize);
      widerContext = windowSegs.map((s) => `Speaker: ${s.text}`).join("\n");
      break;
    }
    case "summary-recent": {
      const windowSegs = available.slice(-settings.windowSize);
      widerContext = windowSegs.map((s) => `Speaker: ${s.text}`).join("\n");
      summary = runningSummary || "No structured state yet.";
      break;
    }
  }

  return {
    latestUtterance: `Speaker: ${latest.text}`,
    recentExchange,
    widerContext,
    conversationSummary: summary,
  };
}

/**
 * Called periodically to update the running summary via LLM.
 * Returns true if a summary update was triggered.
 */
export async function maybeUpdateSummary(
  segments: TranscriptSegment[],
  currentTime: number,
  settings: AppSettings,
  llmCall: (systemPrompt: string, userPrompt: string) => Promise<string>
): Promise<boolean> {
  if (settings.contextMode !== "summary-recent") return false;

  const available = getSegmentsUpTo(segments, currentTime);
  const currentIndex = available.length - 1;

  // Check if enough new segments have passed since last summary
  if (currentIndex - lastSummarizedIndex < settings.summaryRefreshInterval) {
    return false;
  }

  // Summarize everything up to the window boundary
  const boundaryIndex = Math.max(0, available.length - settings.windowSize);
  const toSummarize = available.slice(0, boundaryIndex);
  if (toSummarize.length === 0) return false;

  const transcript = toSummarize.map((s) => s.text).join(" ");

  const systemPrompt =
    "You are a conversation summarizer. Produce a concise running summary of the conversation so far. Focus on: key topics discussed, claims made, decisions reached, and open questions. Keep it under 300 words.";
  const userPrompt = runningSummary
    ? `Previous summary:\n${runningSummary}\n\nNew content to incorporate:\n${transcript}`
    : `Summarize this conversation:\n${transcript}`;

  try {
    runningSummary = await llmCall(systemPrompt, userPrompt);
    lastSummarizedIndex = currentIndex;
    segmentsSinceLastSummary = 0;
    return true;
  } catch (err) {
    console.error("[transcript] summary update failed:", err);
    return false;
  }
}
