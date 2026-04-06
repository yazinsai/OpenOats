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

// --- Summary state ---
let runningSummary = "";
let summaryCoversUpToIndex = -1;
let summaryInFlight = false;

export function resetSummary(): void {
  runningSummary = "";
  summaryCoversUpToIndex = -1;
  summaryInFlight = false;
}

export function getSummary(): string {
  return runningSummary;
}

/**
 * Ensure a summary exists that covers content before the rolling window.
 * Called before every generation. Handles both forward playback and seeks.
 */
export async function ensureSummary(
  segments: TranscriptSegment[],
  currentTime: number,
  settings: AppSettings,
  llmCall: (systemPrompt: string, userPrompt: string) => Promise<string>
): Promise<void> {
  if (summaryInFlight) return;

  const available = getSegmentsUpTo(segments, currentTime);
  if (available.length === 0) return;

  // The window covers the last N segments. Everything before that needs summarizing.
  const windowStart = Math.max(0, available.length - settings.windowSize);
  if (windowStart <= 0) return; // Not enough content to need a summary

  // Did we seek backward? If so, invalidate the summary.
  if (windowStart < summaryCoversUpToIndex) {
    runningSummary = "";
    summaryCoversUpToIndex = -1;
  }

  // Do we need a new/updated summary?
  // Either we have no summary, or there are 15+ new segments since last summary.
  const newSegsSinceSummary = windowStart - Math.max(0, summaryCoversUpToIndex);
  if (summaryCoversUpToIndex >= 0 && newSegsSinceSummary < settings.summaryRefreshInterval) {
    return; // Summary is fresh enough
  }

  // Build the text to summarize: everything from where the last summary left off
  // up to the window boundary.
  const summarizeFrom = Math.max(0, summaryCoversUpToIndex);
  const toSummarize = available.slice(summarizeFrom, windowStart);
  if (toSummarize.length === 0) return;

  const transcript = toSummarize.map((s) => s.text).join(" ");

  const systemPrompt =
    "You are a conversation summarizer for a podcast. Produce a concise running summary. Focus on: key topics discussed, claims made, names mentioned, and open questions. Max 200 words. No preamble — just the summary.";

  const userPrompt = runningSummary
    ? `Previous summary:\n${runningSummary}\n\nNew content to incorporate:\n${transcript}`
    : `Summarize this conversation so far:\n${transcript}`;

  summaryInFlight = true;
  try {
    console.log(`[transcript] summarizing segments ${summarizeFrom}–${windowStart} (${toSummarize.length} segs)`);
    runningSummary = await llmCall(systemPrompt, userPrompt);
    summaryCoversUpToIndex = windowStart;
    console.log(`[transcript] summary updated, covers up to segment ${windowStart}`);
  } catch (err) {
    console.error("[transcript] summary update failed:", err);
  } finally {
    summaryInFlight = false;
  }
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

  const windowSegs = available.slice(-settings.windowSize);
  const widerContext = windowSegs.map((s) => `Speaker: ${s.text}`).join("\n");

  // Summary is always included regardless of context mode
  const conversationSummary = runningSummary || "No structured state yet.";

  return {
    latestUtterance: `Speaker: ${latest.text}`,
    recentExchange,
    widerContext,
    conversationSummary,
  };
}
