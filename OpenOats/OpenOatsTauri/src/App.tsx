import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Utterance, Suggestion, AppSettings } from "./types";
import { ControlBar } from "./components/ControlBar";
import { TranscriptView } from "./components/TranscriptView";
import { SuggestionsView } from "./components/SuggestionsView";
import { NotesView } from "./components/NotesView";
import { SettingsView } from "./components/SettingsView";

// Design system colors
const colors = {
  background: "#111111",
  surface: "#1a1a1a",
  border: "#333333",
  text: "#eeeeee",
  textSecondary: "#888888",
  accent: "#2b7a78",
};

type ModelState = "checking" | "missing" | "downloading" | "ready";
type Tab = "transcript" | "suggestions" | "notes" | "settings";

type WhisperModelId = "auto" | "tiny" | "tiny-en" | "base" | "base-en" | "small" | "small-en";

function resolveWhisperModel(settings: AppSettings | null): Exclude<WhisperModelId, "auto"> {
  const configured = (settings?.whisperModel || "auto") as WhisperModelId;
  const locale = settings?.transcriptionLocale?.trim().toLowerCase() || "";
  const isEnglish = !locale || locale.startsWith("en");

  switch (configured) {
    case "tiny":
      return isEnglish ? "tiny-en" : "tiny";
    case "tiny-en":
      return "tiny-en";
    case "base":
      return isEnglish ? "base-en" : "base";
    case "base-en":
      return "base-en";
    case "small":
      return isEnglish ? "small-en" : "small";
    case "small-en":
      return "small-en";
    case "auto":
    default:
      return isEnglish ? "base-en" : "base";
  }
}

function whisperModelLabel(model: Exclude<WhisperModelId, "auto">): string {
  const labels: Record<Exclude<WhisperModelId, "auto">, string> = {
    tiny: "Whisper tiny (multilingual)",
    "tiny-en": "Whisper tiny-en (English)",
    base: "Whisper base (multilingual)",
    "base-en": "Whisper base-en (English)",
    small: "Whisper small (multilingual)",
    "small-en": "Whisper small-en (English)",
  };
  return labels[model];
}

function App() {
  const [modelState, setModelState] = useState<ModelState>("checking");
  const [downloadProgress, setDownloadProgress] = useState(0);
  const [modelError, setModelError] = useState<string | null>(null);
  const [isRunning, setIsRunning] = useState(false);
  const [utterances, setUtterances] = useState<Utterance[]>([]);
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [tab, setTab] = useState<Tab>("transcript");
  const [currentSessionId, setCurrentSessionId] = useState<string | undefined>();
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [isGeneratingSuggestion, setIsGeneratingSuggestion] = useState(false);
  const [volatileYouText, setVolatileYouText] = useState("");
  const [volatileThemText, setVolatileThemText] = useState("");

  // Load settings on mount
  useEffect(() => {
    invoke<AppSettings>("get_settings")
      .then(setSettings)
      .catch(console.error);
  }, []);

  const handleSettingsChange = useCallback((updated: AppSettings) => {
    setSettings(updated);
  }, []);

  // Check model and set up event listeners
  useEffect(() => {
    if (!settings) {
      return;
    }

    const transcriptionModel = resolveWhisperModel(settings);
    invoke<boolean>("check_model", { model: transcriptionModel })
      .then((ok) => setModelState(ok ? "ready" : "missing"))
      .catch((err) => {
        setModelError(String(err));
        setModelState("missing");
      });

    const unlisteners = [
      listen<{ text: string; speaker: string }>("transcript", (e) => {
        const { text, speaker } = e.payload;
        setUtterances((prev) => [
          ...prev,
          {
            id: crypto.randomUUID(),
            text,
            speaker: speaker === "you" ? "you" : "them",
            timestamp: new Date().toISOString(),
          },
        ]);
        
        // Clear volatile text when finalized
        if (speaker === "you") {
          setVolatileYouText("");
        } else {
          setVolatileThemText("");
        }
      }),
      
      // Listen for volatile/live transcript updates
      listen<{ text: string; speaker: string }>("transcript-volatile", (e) => {
        const { text, speaker } = e.payload;
        if (speaker === "you") {
          setVolatileYouText(text);
        } else {
          setVolatileThemText(text);
        }
      }),

      listen<number>("model-download-progress", (e) => {
        setDownloadProgress(e.payload);
      }),

      listen("model-download-done", () => {
        setModelState("ready");
        setDownloadProgress(0);
        setModelError(null);
      }),

      listen<{ id: string; kind?: "knowledge_base" | "smart_question"; text: string; kbHits?: any[] }>("suggestion", (e) => {
        setIsGeneratingSuggestion(false);
        setSuggestions((prev) => [
          ...prev,
          {
            id: e.payload.id,
            kind: e.payload.kind || "knowledge_base",
            text: e.payload.text,
            timestamp: new Date().toISOString(),
            kbHits: e.payload.kbHits || [],
          },
        ]);
        // Auto-switch to suggestions when one arrives
        setTab("suggestions");
        invoke("show_overlay").catch(() => {});
      }),

      listen("suggestion-generating", () => {
        setIsGeneratingSuggestion(true);
      }),

      listen("suggestion-finished", () => {
        setIsGeneratingSuggestion(false);
      }),
    ];

    return () => {
      unlisteners.forEach((p) => p.then((f) => f()));
    };
  }, [settings]);

  const handleDownload = async () => {
    setModelError(null);
    setModelState("downloading");
    try {
      await invoke("download_model", { model: resolveWhisperModel(settings) });
    } catch (e) {
      setModelError(String(e));
      setModelState("missing");
    }
  };

  const handleStart = async () => {
    try {
      const sessionId = await invoke<string>("start_transcription");
      setCurrentSessionId(sessionId);
      setUtterances([]);
      setSuggestions([]);
      setVolatileYouText("");
      setVolatileThemText("");
      setIsRunning(true);
      setTab("transcript");
    } catch (e) {
      alert(`Failed to start: ${e}`);
    }
  };

  const handleStop = async () => {
    await invoke("stop_transcription");
    setIsRunning(false);
    setVolatileYouText("");
    setVolatileThemText("");
  };

  const handleSuggestionFeedback = useCallback((id: string, helpful: boolean) => {
    // Send feedback to backend
    invoke("suggestion_feedback", { sessionId: currentSessionId, suggestionId: id, helpful }).catch(console.error);
  }, [currentSessionId]);

  const handleSuggestionCopy = useCallback((text: string) => {
    // Optional: track copy events or show toast
    console.log("Copied suggestion:", text.substring(0, 50) + "...");
  }, []);

  const activeWhisperModel = resolveWhisperModel(settings);

  // Loading states
  if (modelState === "checking") {
    return (
      <div style={centerStyle}>
        <LoadingSpinner />
        <p style={{ color: colors.textSecondary, marginTop: 16 }}>Checking model...</p>
      </div>
    );
  }

  if (modelState === "missing") {
    return (
      <div style={centerStyle}>
        <div style={{ textAlign: "center", maxWidth: 320 }}>
          <div style={iconContainerStyle}>🧠</div>
          <h3 style={{ color: colors.text, margin: "0 0 8px", fontSize: 16 }}>
            Transcription Model Required
          </h3>
          <p style={{ color: colors.textSecondary, fontSize: 13, margin: "0 0 20px", lineHeight: 1.5 }}>
            OpenOats needs {whisperModelLabel(activeWhisperModel)} to transcribe conversations locally for {settings?.transcriptionLocale || "the selected language"}.
          </p>
          {modelError && (
            <p style={{ color: "#c0392b", fontSize: 12, margin: "0 0 16px", lineHeight: 1.5 }}>
              {modelError}
            </p>
          )}
          <button onClick={handleDownload} style={primaryBtn}>
            Download {activeWhisperModel} (~150 MB)
          </button>
        </div>
      </div>
    );
  }

  if (modelState === "downloading") {
    return (
      <div style={centerStyle}>
        <div style={{ textAlign: "center", maxWidth: 280 }}>
          <h3 style={{ color: colors.text, margin: "0 0 16px", fontSize: 16 }}>
            🧠 Setting up Whisper
          </h3>
          <div style={{ marginBottom: 12 }}>
            <div
              style={{
                width: 260,
                height: 6,
                background: colors.surface,
                borderRadius: 3,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  width: `${downloadProgress}%`,
                  height: "100%",
                  background: colors.accent,
                  borderRadius: 3,
                  transition: "width 0.3s",
                }}
              />
            </div>
          </div>
          <p style={{ color: colors.textSecondary, fontSize: 12, margin: 0 }}>
            Downloading {activeWhisperModel}... {downloadProgress}%
          </p>
          <p style={{ color: colors.textSecondary, fontSize: 11, margin: "8px 0 0", opacity: 0.7 }}>
            ~150 MB · 30 seconds remaining
          </p>
        </div>
      </div>
    );
  }

  const isLocalMode = settings?.llmProvider === "ollama" && settings?.embeddingProvider === "ollama";
  const modelName =
    settings?.llmProvider === "ollama"
      ? settings.ollamaLlmModel || "Unknown"
      : settings?.selectedModel || "Unknown";
  const kbConnected = !!settings?.kbFolderPath;

  const tabs: { key: Tab; label: string; badge?: number }[] = [
    { key: "transcript", label: "Transcript" },
    { key: "suggestions", label: "Suggestions", badge: suggestions.length },
    { key: "notes", label: "Notes" },
    { key: "settings", label: "Settings" },
  ];

  return (
    <div
      style={{
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        background: colors.background,
        color: colors.text,
        fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      }}
    >
      {/* Control Bar */}
      <ControlBar
        isRunning={isRunning}
        onStart={handleStart}
        onStop={handleStop}
        modelName={modelName}
        whisperModel={activeWhisperModel}
        transcriptionLocale={settings?.transcriptionLocale || ""}
        kbConnected={kbConnected}
        kbFileCount={0} // Would come from backend
        isLocalMode={isLocalMode}
      />

      {/* Tab Bar */}
      <div
        style={{
          display: "flex",
          borderBottom: `1px solid ${colors.border}`,
          background: colors.surface,
        }}
      >
        {tabs.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            style={{
              padding: "10px 16px",
              background: "transparent",
              color: tab === t.key ? colors.accent : colors.textSecondary,
              border: "none",
              borderBottom: tab === t.key ? `2px solid ${colors.accent}` : "2px solid transparent",
              cursor: "pointer",
              fontSize: 13,
              fontWeight: tab === t.key ? 600 : 400,
              display: "flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            {t.label}
            {t.badge !== undefined && t.badge > 0 && (
              <span
                style={{
                  background: colors.accent,
                  color: "#fff",
                  fontSize: 10,
                  fontWeight: 600,
                  padding: "2px 6px",
                  borderRadius: 10,
                  minWidth: 18,
                  textAlign: "center",
                }}
              >
                {t.badge > 99 ? "99+" : t.badge}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Tab Content */}
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {tab === "transcript" && (
          <TranscriptView
            utterances={utterances}
            volatileYouText={volatileYouText}
            volatileThemText={volatileThemText}
          />
        )}
        {tab === "suggestions" && (
          <SuggestionsView
            suggestions={suggestions}
            isGenerating={isGeneratingSuggestion}
            kbConnected={kbConnected}
            kbFileCount={0}
            onFeedback={handleSuggestionFeedback}
            onCopy={handleSuggestionCopy}
          />
        )}
        {tab === "settings" && (
          <SettingsView
            settings={settings}
            onSettingsChange={handleSettingsChange}
          />
        )}
        {tab === "notes" && <NotesView sessionId={currentSessionId} />}
      </div>
    </div>
  );
}

// Loading spinner component
function LoadingSpinner() {
  return (
    <div
      style={{
        width: 32,
        height: 32,
        border: `3px solid ${colors.surface}`,
        borderTopColor: colors.accent,
        borderRadius: "50%",
        animation: "spin 1s linear infinite",
      }}
    >
      <style>{`
        @keyframes spin {
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}

const centerStyle: React.CSSProperties = {
  height: "100vh",
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  background: colors.background,
};

const iconContainerStyle: React.CSSProperties = {
  width: 64,
  height: 64,
  borderRadius: 16,
  background: `${colors.accent}15`,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  fontSize: 32,
  marginBottom: 16,
};

const primaryBtn: React.CSSProperties = {
  padding: "10px 24px",
  background: colors.accent,
  color: "#fff",
  border: "none",
  borderRadius: 6,
  cursor: "pointer",
  fontSize: 14,
  fontWeight: 600,
  transition: "background 0.2s",
};

export default App;
