import type { TranscriptSegment, AppSettings } from "./types.ts";
import { YouTubePlayer, extractVideoId } from "./player.ts";
import {
  fetchTranscript,
  findActiveSegmentIndex,
  buildContextWindow,
  maybeUpdateSummary,
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
  renderFilterLog,
  setStatus,
} from "./ui.ts";

let settings: AppSettings = loadSettings();
let segments: TranscriptSegment[] = [];
let lastTriggeredSegmentIndex = -1;
let isGenerating = false;

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
  segments = [];

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

  // Trigger sidecast when crossing a new segment boundary
  if (idx > lastTriggeredSegmentIndex && idx >= 0) {
    lastTriggeredSegmentIndex = idx;
    triggerSidecast(currentTime);
  }
}

function onSeek(currentTime: number) {
  if (segments.length === 0) return;

  const idx = findActiveSegmentIndex(segments, currentTime);
  lastTriggeredSegmentIndex = idx;

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

    // Maybe update summary
    await maybeUpdateSummary(segments, effectiveTime, settings, (sys, usr) =>
      llmCall(sys, usr, settings)
    );

    const context = buildContextWindow(segments, effectiveTime, settings);
    if (!context.latestUtterance) {
      setStatus("ok", "No transcript content at current position");
      isGenerating = false;
      return;
    }

    const result = await generate(context, effectiveTime, settings);

    // Cooldown skip — keep the existing UI intact
    if (result.rawResponse === "(skipped: cooldown)") {
      setStatus("ok", "Cooldown — waiting");
      isGenerating = false;
      return;
    }

    // Render output
    renderSidecastBubbles(
      document.getElementById("sidecast-bubbles")!,
      getMessages(),
      settings.personas
    );

    renderFilterLog(
      document.getElementById("filter-log")!,
      result.filtered,
      result.promptCharCount
    );

    const rawEl = document.getElementById("raw-json")!;
    rawEl.textContent = result.rawResponse;

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
  document.getElementById("sidecast-bubbles")!.innerHTML = "";
  document.getElementById("filter-log")!.innerHTML = "";
  document.getElementById("raw-json")!.textContent = "";
  setStatus("ok", "Cleared");
});

document.getElementById("toggle-raw")!.addEventListener("click", () => {
  const el = document.getElementById("raw-json")!;
  el.style.display = el.style.display === "none" ? "block" : "none";
});
