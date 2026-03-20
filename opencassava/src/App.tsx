import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Utterance, Suggestion, AppSettings, EnhancedNotes, SessionDetails } from "./types";
import { ControlBar } from "./components/ControlBar";
import { TranscriptView } from "./components/TranscriptView";
import { SuggestionsView } from "./components/SuggestionsView";
import { NotesView } from "./components/NotesView";
import { SettingsView } from "./components/SettingsView";
import { SessionSidebar } from "./components/SessionSidebar";
import { TranscriptSearch } from "./components/TranscriptSearch";
import { ExportMenu } from "./components/ExportMenu";
import { useKeyboardShortcuts } from "./hooks/useKeyboardShortcuts";
import { colors, typography, spacing } from "./theme";

type ModelState = "checking" | "missing" | "downloading" | "ready";
type Tab = "transcript" | "suggestions" | "notes" | "settings";
type SuggestionCheckEvent = {
  checkedAt: string;
  surfaced: boolean;
};

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

function compactModelName(modelName: string): string {
  if (!modelName) return "Unknown";
  if (modelName.length <= 20) return modelName;
  return modelName.split("/").pop() || modelName;
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
  const [currentSessionNotes, setCurrentSessionNotes] = useState<EnhancedNotes | null>(null);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [isGeneratingSuggestion, setIsGeneratingSuggestion] = useState(false);
  const [lastSuggestionCheckAt, setLastSuggestionCheckAt] = useState<string | null>(null);
  const [lastSuggestionCheckSurfaced, setLastSuggestionCheckSurfaced] = useState<boolean | null>(null);
  const [volatileYouText, setVolatileYouText] = useState("");
  const [volatileThemText, setVolatileThemText] = useState("");
  
  // New UX state
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [showExport, setShowExport] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<number[]>([]);
  const [currentSearchIndex, setCurrentSearchIndex] = useState(0);
  const [audioLevel, setAudioLevel] = useState(0);
  // Load settings on mount
  useEffect(() => {
    invoke<AppSettings>("get_settings")
      .then(setSettings)
      .catch(console.error);
  }, []);

  const handleSettingsChange = useCallback((updated: AppSettings) => {
    setSettings(updated);
  }, []);

  // Keyboard shortcuts
  useKeyboardShortcuts({
    onStartStop: () => {
      if (modelState === "ready") {
        isRunning ? handleStop() : handleStart();
      }
    },
    onFocusSearch: () => {
      setShowSearch(true);
      setTab("transcript");
    },
    onExportTranscript: () => {
      if (utterances.length > 0) {
        setShowExport(true);
      }
    },
    onToggleSidebar: () => setSidebarOpen((prev) => !prev),
  });

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
        
        if (speaker === "you") {
          setVolatileYouText("");
        } else {
          setVolatileThemText("");
        }
      }),
      
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
        setTab("suggestions");
      }),

      listen("suggestion-generating", () => {
        setIsGeneratingSuggestion(true);
      }),

      listen("suggestion-finished", () => {
        setIsGeneratingSuggestion(false);
      }),

      listen<SuggestionCheckEvent>("suggestion-check-started", (e) => {
        setLastSuggestionCheckAt(e.payload.checkedAt);
        setLastSuggestionCheckSurfaced(false);
      }),

      listen<SuggestionCheckEvent>("suggestion-check-finished", (e) => {
        setLastSuggestionCheckAt(e.payload.checkedAt);
        setLastSuggestionCheckSurfaced(e.payload.surfaced);
      }),

      listen<{ you: number; them: number }>("audio-level", (e) => {
        setAudioLevel(e.payload.you);
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
      setCurrentSessionNotes(null);
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

  const handleDismissSuggestion = useCallback((id: string) => {
    setSuggestions((prev) => prev.filter((s) => s.id !== id));
    invoke("suggestion_feedback", { sessionId: currentSessionId, suggestionId: id, helpful: false }).catch(console.error);
  }, [currentSessionId]);

  const handleSearch = (query: string) => {
    setSearchQuery(query);
    if (!query.trim()) {
      setSearchResults([]);
      setCurrentSearchIndex(0);
      return;
    }

    const indices: number[] = [];
    const lowerQuery = query.toLowerCase();
    utterances.forEach((u, i) => {
      if (u.text.toLowerCase().includes(lowerQuery)) {
        indices.push(i);
      }
    });
    setSearchResults(indices);
    setCurrentSearchIndex(0);
  };

  const handleLoadSession = async (sessionId: string) => {
    try {
      const sessionData = await invoke<SessionDetails>("load_session", { id: sessionId });
      setUtterances(sessionData.transcript);
      setCurrentSessionNotes(sessionData.notes ?? null);
      setCurrentSessionId(sessionId);
      setTab("transcript");
    } catch (err) {
      console.error("Failed to load session:", err);
    }
  };

  const activeWhisperModel = resolveWhisperModel(settings);

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
            OpenCassava needs {whisperModelLabel(activeWhisperModel)} to transcribe conversations locally.
          </p>
          {modelError && (
            <p style={{ color: colors.error, fontSize: 12, margin: "0 0 16px", lineHeight: 1.5 }}>
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
          <h3 style={{ color: colors.text, margin: "0 0 16px", fontSize: 16 }}>🧠 Setting up Whisper</h3>
          <div style={{ marginBottom: 12 }}>
            <div style={{ width: 260, height: 6, background: colors.surfaceElevated, borderRadius: 3, overflow: "hidden" }}>
              <div style={{ width: `${downloadProgress}%`, height: "100%", background: colors.accent, borderRadius: 3, transition: "width 0.3s" }} />
            </div>
          </div>
          <p style={{ color: colors.textSecondary, fontSize: 12, margin: 0 }}>
            Downloading {activeWhisperModel}... {downloadProgress}%
          </p>
        </div>
      </div>
    );
  }

  const isLocalMode = settings?.llmProvider === "ollama" && settings?.embeddingProvider === "ollama";
  const modelName = settings?.llmProvider === "ollama" ? settings.ollamaLlmModel || "Unknown" : settings?.selectedModel || "Unknown";
  const kbConnected = !!settings?.kbFolderPath;

  const tabs: { key: Tab; label: string; badge?: number }[] = [
    { key: "transcript", label: "Transcript" },
    { key: "suggestions", label: "Suggestions", badge: suggestions.length },
    { key: "notes", label: "Notes" },
    { key: "settings", label: "Settings" },
  ];

  return (
    <div style={{ height: "100vh", display: "flex", flexDirection: "column", background: colors.background, color: colors.text, fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif" }}>
      {/* Session Sidebar */}
      <SessionSidebar
        currentSessionId={currentSessionId}
        onSelectSession={handleLoadSession}
        isOpen={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
      />

      {/* Search Bar */}
      {showSearch && tab === "transcript" && (
        <TranscriptSearch
          onSearch={handleSearch}
          onClose={() => setShowSearch(false)}
          resultCount={searchResults.length}
          currentIndex={currentSearchIndex}
          onNext={() => setCurrentSearchIndex((i) => Math.min(i + 1, searchResults.length - 1))}
          onPrev={() => setCurrentSearchIndex((i) => Math.max(i - 1, 0))}
        />
      )}

      {/* Export Modal */}
      {showExport && <ExportMenu utterances={utterances} onClose={() => setShowExport(false)} />}

      {/* Main Toolbar */}
      <div style={{ display: "flex", alignItems: "center", gap: spacing[2], padding: `${spacing[2]}px ${spacing[3]}px`, background: colors.surface, borderBottom: `1px solid ${colors.border}` }}>
        <button
          onClick={() => setSidebarOpen(true)}
          style={{ padding: `${spacing[2]}px`, background: colors.background, border: `1px solid ${colors.border}`, borderRadius: 6, fontSize: typography.md, cursor: "pointer", color: colors.text }}
          title="Session History (Cmd/Ctrl+B)"
        >
          ☰
        </button>
        <div style={{ flex: 1 }} />
        <div style={{ display: "flex", gap: spacing[2] }}>
          <button
            onClick={() => setShowSearch(true)}
            disabled={utterances.length === 0}
            style={{ padding: `${spacing[2]}px ${spacing[3]}px`, background: colors.background, border: `1px solid ${colors.border}`, borderRadius: 6, fontSize: typography.md, cursor: utterances.length === 0 ? "not-allowed" : "pointer", opacity: utterances.length === 0 ? 0.5 : 1, color: colors.text }}
            title="Search (Cmd/Ctrl+F)"
          >
            🔍 Search
          </button>
          <button
            onClick={() => setShowExport(true)}
            disabled={utterances.length === 0}
            style={{ padding: `${spacing[2]}px ${spacing[3]}px`, background: colors.background, border: `1px solid ${colors.border}`, borderRadius: 6, fontSize: typography.md, cursor: utterances.length === 0 ? "not-allowed" : "pointer", opacity: utterances.length === 0 ? 0.5 : 1, color: colors.text }}
            title="Export (Cmd/Ctrl+E)"
          >
            📤 Export
          </button>
        </div>
      </div>

      {/* Control Bar */}
      <ControlBar
        isRunning={isRunning}
        onStart={handleStart}
        onStop={handleStop}
        kbConnected={kbConnected}
        kbFileCount={0}
        isSuggestionAnalyzing={isGeneratingSuggestion}
        lastSuggestionCheckAt={lastSuggestionCheckAt}
        lastSuggestionCheckSurfaced={lastSuggestionCheckSurfaced}
        audioLevel={audioLevel}
      />

      {/* Tab Bar */}
      <div style={{ display: "flex", borderBottom: `1px solid ${colors.border}`, background: colors.surface }}>
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
              fontSize: typography.md,
              fontWeight: tab === t.key ? 600 : 400,
              display: "flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            {t.label}
            {t.badge !== undefined && t.badge > 0 && (
              <span style={{ background: colors.accent, color: colors.textInverse, fontSize: 10, fontWeight: 600, padding: "2px 6px", borderRadius: 10, minWidth: 18, textAlign: "center" }}>
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
            searchQuery={searchQuery}
            searchResults={searchResults}
            currentSearchIndex={currentSearchIndex}
          />
        )}
        {tab === "suggestions" && (
          <SuggestionsView
            suggestions={suggestions}
            isGenerating={isGeneratingSuggestion}
            kbConnected={kbConnected}
            kbFileCount={0}
            lastCheckedAt={lastSuggestionCheckAt}
            lastCheckSurfaced={lastSuggestionCheckSurfaced}
            onDismiss={handleDismissSuggestion}
            onInjectTest={(s) =>
              setSuggestions((prev) => [
                ...prev,
                {
                  ...s,
                  kind: s.kind as Suggestion["kind"],
                  timestamp: new Date().toISOString(),
                },
              ])
            }
          />
        )}
        {tab === "settings" && (
          <SettingsView settings={settings} onSettingsChange={handleSettingsChange} />
        )}
        {tab === "notes" && (
          <NotesView
            sessionId={currentSessionId}
            initialNotes={currentSessionNotes}
            onNotesChange={setCurrentSessionNotes}
          />
        )}
      </div>

      {/* Bottom Status Bar */}
      <div
        style={{
          padding: `${spacing[1]}px ${spacing[3]}px`,
          background: colors.surfaceElevated,
          borderTop: `1px solid ${colors.border}`,
          fontSize: typography.xs,
          color: colors.textMuted,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: spacing[3],
          flexWrap: "wrap",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: spacing[2], flexWrap: "wrap" }}>
          <span
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: `${(isLocalMode ? colors.success : colors.you)}15`,
              color: isLocalMode ? colors.success : colors.you,
              borderRadius: 12,
              fontWeight: 600,
            }}
            title={isLocalMode ? "Local mode - no data leaves your device" : "Cloud mode - using external APIs"}
          >
            {isLocalMode ? "LLM Local" : "LLM Cloud"}
          </span>
          <span
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: colors.background,
              color: colors.textSecondary,
              borderRadius: 12,
              fontWeight: 500,
              fontFamily: "SF Mono, Monaco, monospace",
            }}
            title="Active AI model"
          >
            {compactModelName(modelName)}
          </span>
          <span
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: colors.surface,
              color: colors.them,
              borderRadius: 12,
              fontWeight: 500,
              fontFamily: "SF Mono, Monaco, monospace",
            }}
            title="Active Whisper transcription model"
          >
            {activeWhisperModel} | {settings?.transcriptionLocale || "auto"}
          </span>
        </div>

        <div style={{ display: "flex", gap: spacing[4], flexWrap: "wrap", justifyContent: "center" }}>
          <span>Cmd/Ctrl+Shift+S: Start/Stop</span>
          <span>Cmd/Ctrl+F: Search</span>
          <span>Cmd/Ctrl+E: Export</span>
          <span>Cmd/Ctrl+B: History</span>
          <span>Esc: Close</span>
        </div>
      </div>
    </div>
  );
}

function LoadingSpinner() {
  return (
    <div style={{ width: 32, height: 32, border: `3px solid ${colors.surfaceElevated}`, borderTopColor: colors.accent, borderRadius: "50%", animation: "spin 1s linear infinite" }}>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
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
  color: colors.textInverse,
  border: "none",
  borderRadius: 6,
  cursor: "pointer",
  fontSize: 14,
  fontWeight: 600,
};

export default App;
