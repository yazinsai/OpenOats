import express from "express";

const app = express();
const PORT = 3001;

app.use((_req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  next();
});

interface TimedTextEvent {
  start: number;
  duration: number;
  text: string;
}

function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\n/g, " ");
}

function parseTimedTextXML(xml: string): TimedTextEvent[] {
  const segments: TimedTextEvent[] = [];
  const regex = /<text start="([^"]+)" dur="([^"]+)"[^>]*>([\s\S]*?)<\/text>/g;
  let match;
  while ((match = regex.exec(xml)) !== null) {
    segments.push({
      start: parseFloat(match[1]),
      duration: parseFloat(match[2]),
      text: decodeHTMLEntities(match[3].replace(/<[^>]+>/g, "").trim()),
    });
  }
  return segments;
}

async function fetchTranscript(videoId: string): Promise<TimedTextEvent[]> {
  // Fetch the YouTube watch page to extract caption track URL
  const watchURL = `https://www.youtube.com/watch?v=${videoId}`;
  const res = await fetch(watchURL, {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      "Accept-Language": "en-US,en;q=0.9",
    },
  });
  const html = await res.text();

  // Extract captions JSON from the page
  const captionMatch = html.match(/"captionTracks":\s*(\[.*?\])/);
  if (!captionMatch) {
    throw new Error("No caption tracks found for this video");
  }

  const tracks = JSON.parse(captionMatch[1]) as Array<{
    baseUrl: string;
    languageCode: string;
  }>;

  // Prefer English, fall back to first available
  const enTrack =
    tracks.find((t) => t.languageCode === "en") ||
    tracks.find((t) => t.languageCode.startsWith("en")) ||
    tracks[0];
  if (!enTrack) {
    throw new Error("No suitable caption track found");
  }

  const captionRes = await fetch(enTrack.baseUrl);
  const xml = await captionRes.text();
  return parseTimedTextXML(xml);
}

app.get("/api/transcript", async (req, res) => {
  const videoId = req.query.v as string;
  if (!videoId) {
    res.status(400).json({ error: "Missing ?v= parameter" });
    return;
  }

  try {
    const segments = await fetchTranscript(videoId);
    res.json({ segments });
  } catch (err: any) {
    console.error(`[transcript-proxy] ${err.message}`);
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`[transcript-proxy] listening on http://localhost:${PORT}`);
});
