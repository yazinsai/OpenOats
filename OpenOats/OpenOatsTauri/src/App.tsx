import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Utterance, Suggestion } from "./types";
import { ControlBar } from "./components/ControlBar";
import { TranscriptView } from "./components/TranscriptView";
import { SuggestionsView } from "./components/SuggestionsView";
import { NotesView } from "./components/NotesView";
import { SettingsView } from "./components/SettingsView";

type ModelState = "checking" | "missing" | "downloading" | "ready";
type Tab = "transcript" | "suggestions" | "notes" | "settings";

function App() {
  const [modelState, setModelState] = useState<ModelState>("checking");
  const [downloadProgress, setDownloadProgress] = useState(0);
  const [isRunning, setIsRunning] = useState(false);
  const [utterances, setUtterances] = useState<Utterance[]>([]);
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [tab, setTab] = useState<Tab>("transcript");
  const [currentSessionId, setCurrentSessionId] = useState<string | undefined>();

  useEffect(() => {
    invoke<boolean>("check_model").then((ok) =>
      setModelState(ok ? "ready" : "missing")
    ).catch(() => setModelState("missing"));

    const unlisteners = [
      listen<{ text: string; speaker: string }>("transcript", (e) => {
        const { text, speaker } = e.payload;
        setUtterances((prev) => [...prev, {
          id: crypto.randomUUID(),
          text,
          speaker: speaker === "you" ? "you" : "them",
          timestamp: new Date().toISOString(),
        }]);
      }),
      listen<number>("model-download-progress", (e) => {
        setDownloadProgress(e.payload);
      }),
      listen("model-download-done", () => {
        setModelState("ready");
        setDownloadProgress(0);
      }),
      listen<{ id: string; text: string }>("suggestion", (e) => {
        setSuggestions((prev) => [...prev, {
          id: e.payload.id,
          text: e.payload.text,
          timestamp: new Date().toISOString(),
          kbHits: [],
        }]);
        setTab("suggestions");
      }),
    ];

    return () => { unlisteners.forEach((p) => p.then((f) => f())); };
  }, []);

  const handleDownload = async () => {
    setModelState("downloading");
    try {
      await invoke("download_model");
    } catch (e) {
      setModelState("missing");
    }
  };

  const handleStart = async () => {
    try {
      const sessionId = await invoke<string>("start_transcription");
      setCurrentSessionId(sessionId);
      setUtterances([]);
      setSuggestions([]);
      setIsRunning(true);
    } catch (e) {
      alert(`Failed to start: ${e}`);
    }
  };

  const handleStop = async () => {
    await invoke("stop_transcription");
    setIsRunning(false);
  };

  if (modelState === "checking") {
    return <div style={centerStyle}>Checking model…</div>;
  }

  if (modelState === "missing") {
    return (
      <div style={centerStyle}>
        <p style={{ color: "#ccc", marginBottom: 16 }}>Whisper model not downloaded</p>
        <button onClick={handleDownload} style={primaryBtn}>Download Model (~150 MB)</button>
      </div>
    );
  }

  if (modelState === "downloading") {
    return (
      <div style={centerStyle}>
        <p style={{ color: "#ccc", marginBottom: 12 }}>Downloading model… {downloadProgress}%</p>
        <div style={{ width: 260, height: 6, background: "#333", borderRadius: 3 }}>
          <div style={{ width: `${downloadProgress}%`, height: "100%", background: "#3498db", borderRadius: 3, transition: "width 0.3s" }} />
        </div>
      </div>
    );
  }

  const tabs: { key: Tab; label: string }[] = [
    { key: "transcript", label: "Transcript" },
    { key: "suggestions", label: `Suggestions${suggestions.length > 0 ? ` (${suggestions.length})` : ""}` },
    { key: "notes", label: "Notes" },
    { key: "settings", label: "Settings" },
  ];

  return (
    <div style={{ height: "100vh", display: "flex", flexDirection: "column", background: "#111", color: "#eee", fontFamily: "system-ui, sans-serif" }}>
      <ControlBar isRunning={isRunning} onStart={handleStart} onStop={handleStop} />

      {/* Tab bar */}
      <div style={{ display: "flex", borderBottom: "1px solid #333" }}>
        {tabs.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            style={{
              padding: "8px 16px",
              background: "transparent",
              color: tab === t.key ? "#3498db" : "#888",
              border: "none",
              borderBottom: tab === t.key ? "2px solid #3498db" : "2px solid transparent",
              cursor: "pointer",
              fontSize: 13,
              fontWeight: tab === t.key ? 600 : 400,
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {tab === "transcript" && <TranscriptView utterances={utterances} />}
        {tab === "suggestions" && <SuggestionsView suggestions={suggestions} />}
        {tab === "notes" && <NotesView sessionId={currentSessionId} />}
        {tab === "settings" && <SettingsView />}
      </div>
    </div>
  );
}

const centerStyle: React.CSSProperties = {
  height: "100vh",
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  background: "#111",
  color: "#eee",
};

const primaryBtn: React.CSSProperties = {
  padding: "8px 24px",
  background: "#3498db",
  color: "#fff",
  border: "none",
  borderRadius: 4,
  cursor: "pointer",
  fontSize: 14,
};

export default App;
