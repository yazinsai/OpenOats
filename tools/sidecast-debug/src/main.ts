import type { TranscriptSegment, AppSettings, DebugLogEntry } from "./types.ts";
import { YouTubePlayer, extractVideoId } from "./player.ts";
import {
  fetchTranscript,
  findActiveSegmentIndex,
  buildContextWindow,
  ensureSummary,
  resetSummary,
} from "./transcript.ts";
import { loadSettings, saveSettings } from "./settings.ts";
import {
  generate,
  getMessages,
  clearState,
  llmCall,
} from "./sidecast.ts";
import {
  renderSettingsPanel,
  renderTranscriptViewer,
  renderSidecastBubbles,
  renderDebugLog,
  setStatus,
} from "./ui.ts";

let settings: AppSettings = loadSettings();
let segments: TranscriptSegment[] = [];
let lastTriggeredSegmentIndex = -1;
let lastGeneratedSegmentIndex = -1;
let isGenerating = false;
let debugLog: DebugLogEntry[] = [];
let debugLogCounter = 0;

const MIN_NEW_SEGMENTS_BEFORE_GENERATION = 10;

// --- Render settings panel ---
function refreshSettings() {
  renderSettingsPanel(
    document.getElementById("settings-panel")!,
    settings,
    (updated) => {
      settings = updated;
      refreshSettings(); // Re-render on structural changes (persona add/remove)
    }
  );
}
refreshSettings();

// --- YouTube player ---
const player = new YouTubePlayer(
  "yt-player-container",
  onTimeUpdate,
  onSeek
);

// --- URL loading ---
document.getElementById("yt-load")!.addEventListener("click", loadVideo);
document.getElementById("yt-url")!.addEventListener("keydown", (e) => {
  if ((e as KeyboardEvent).key === "Enter") loadVideo();
});

async function loadVideo() {
  const url = (document.getElementById("yt-url") as HTMLInputElement).value;
  const videoId = extractVideoId(url);
  if (!videoId) {
    setStatus("error", "Invalid YouTube URL");
    return;
  }

  setStatus("loading", "Loading video and transcript...");
  clearState();
  resetSummary();
  lastTriggeredSegmentIndex = -1;
  lastGeneratedSegmentIndex = -1;
  segments = [];
  debugLog = [];
  debugLogCounter = 0;

  try {
    const [, transcriptSegments] = await Promise.all([
      player.loadVideo(videoId),
      fetchTranscript(videoId),
    ]);
    segments = transcriptSegments;
    renderTranscriptViewer(
      document.getElementById("transcript-viewer")!,
      segments,
      -1,
      (time) => player.seekTo(time)
    );
    setStatus("ok", `Loaded ${segments.length} transcript segments`);
  } catch (err: any) {
    setStatus("error", err.message);
  }
}

// --- Playback callbacks ---
function onTimeUpdate(currentTime: number) {
  if (segments.length === 0) return;

  const idx = findActiveSegmentIndex(segments, currentTime);
  renderTranscriptViewer(
    document.getElementById("transcript-viewer")!,
    segments,
    idx,
    (time) => player.seekTo(time)
  );

  // Trigger sidecast when enough new segments have accumulated
  if (idx > lastTriggeredSegmentIndex && idx >= 0) {
    lastTriggeredSegmentIndex = idx;
    const newSegsSinceLastGen = idx - lastGeneratedSegmentIndex;
    if (newSegsSinceLastGen >= MIN_NEW_SEGMENTS_BEFORE_GENERATION) {
      triggerSidecast(currentTime);
    }
  }
}

function onSeek(currentTime: number) {
  if (segments.length === 0) return;

  const idx = findActiveSegmentIndex(segments, currentTime);
  lastTriggeredSegmentIndex = idx;

  // Seeks always invalidate the summary — it will rebuild for the new position
  resetSummary();

  renderTranscriptViewer(
    document.getElementById("transcript-viewer")!,
    segments,
    idx,
    (time) => player.seekTo(time)
  );

  triggerSidecast(currentTime);
}

// --- Sidecast generation ---
async function triggerSidecast(currentTime: number) {
  if (isGenerating) return;
  isGenerating = true;
  setStatus("loading", "Generating sidecast...");

  try {
    // If video hasn't started, use a small offset so the first segment is included
    const effectiveTime = currentTime < 0.5 && segments.length > 0
      ? segments[0].start + 0.01
      : currentTime;

    // Ensure summary covers content before the rolling window
    await ensureSummary(segments, effectiveTime, settings, (sys, usr) =>
      llmCall(sys, usr, settings)
    );

    const context = buildContextWindow(segments, effectiveTime, settings);
    if (!context.latestUtterance) {
      setStatus("ok", "No transcript content at current position");
      isGenerating = false;
      return;
    }

    const result = await generate(context, effectiveTime, settings);

    // Cooldown skip — keep the existing bubbles and log intact
    if (result.skipped) {
      setStatus("ok", "Cooldown — waiting");
      isGenerating = false;
      return;
    }

    // Track that a real generation happened at this segment
    lastGeneratedSegmentIndex = lastTriggeredSegmentIndex;

    // Add to debug history
    debugLog.push({
      id: ++debugLogCounter,
      timestamp: effectiveTime,
      wallTime: new Date(),
      result,
    });
    renderDebugLog(document.getElementById("debug-log")!, debugLog);

    // Render output
    renderSidecastBubbles(
      document.getElementById("sidecast-bubbles")!,
      getMessages(),
      settings.personas
    );

    if (result.accepted.length > 0 || result.filtered.length > 0) {
      setStatus("ok", `Generated: ${result.accepted.length} shown, ${result.filtered.length} filtered`);
    } else {
      setStatus("ok", "No new sidecast output");
    }
  } catch (err: any) {
    console.error("[sidecast] generation error:", err);
    setStatus("error", `Generation failed: ${err.message}`);
  } finally {
    isGenerating = false;
  }
}

// --- Manual controls ---
document.getElementById("generate-btn")!.addEventListener("click", () => {
  const currentTime = player.getCurrentTime();
  triggerSidecast(currentTime);
});

document.getElementById("clear-btn")!.addEventListener("click", () => {
  clearState();
  debugLog = [];
  debugLogCounter = 0;
  document.getElementById("sidecast-bubbles")!.innerHTML = "";
  document.getElementById("debug-log")!.innerHTML = "";
  setStatus("ok", "Cleared");
});

// --- Demo mode toggle ---
const demoBtn = document.getElementById("demo-btn")!;
const expandIcon = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="10 2 14 2 14 6"/><polyline points="6 14 2 14 2 10"/><polyline points="14 10 14 14 10 14"/><polyline points="2 6 2 2 6 2"/></svg>`;
const collapseIcon = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 14 4 10 0 10"/><polyline points="12 2 12 6 16 6"/><polyline points="0 6 4 6 4 2"/><polyline points="16 10 12 10 12 14"/></svg>`;
demoBtn.addEventListener("click", () => {
  const app = document.getElementById("app")!;
  const isDemo = app.classList.toggle("demo-mode");
  demoBtn.innerHTML = isDemo ? collapseIcon : expandIcon;
});
