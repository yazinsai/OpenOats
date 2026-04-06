import express from "express";
// youtube-transcript has broken ESM packaging — import from the ESM bundle directly
import { fetchTranscript as ytFetchTranscript } from "youtube-transcript/dist/youtube-transcript.esm.js";

const app = express();
const PORT = 3001;

app.use((_req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  next();
});

interface TranscriptSegment {
  start: number;
  duration: number;
  text: string;
}

app.get("/api/transcript", async (req, res) => {
  const videoId = req.query.v as string;
  if (!videoId) {
    res.status(400).json({ error: "Missing ?v= parameter" });
    return;
  }

  try {
    const raw = await ytFetchTranscript(videoId, { lang: "en" });
    const segments: TranscriptSegment[] = raw.map((entry: any) => ({
      start: entry.offset / 1000, // offset is in ms
      duration: entry.duration / 1000,
      text: entry.text,
    }));
    console.log(`[transcript-proxy] ${videoId}: ${segments.length} segments`);
    res.json({ segments });
  } catch (err: any) {
    console.error(`[transcript-proxy] ${err.message}`);
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`[transcript-proxy] listening on http://localhost:${PORT}`);
});
