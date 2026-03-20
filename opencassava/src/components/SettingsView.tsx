import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { ApiKeys, AppSettings } from "../types";
import { colors, typography, spacing } from "../theme";

type Tab = "general" | "ai" | "advanced";

const transcriptionLocaleOptions = [
  { value: "en-US", label: "English (US)" },
  { value: "en-GB", label: "English (UK)" },
  { value: "es-ES", label: "Spanish (Spain)" },
  { value: "es-CO", label: "Spanish (Colombia)" },
  { value: "es-MX", label: "Spanish (Mexico)" },
  { value: "fr-FR", label: "French" },
  { value: "de-DE", label: "German" },
  { value: "pt-BR", label: "Portuguese (Brazil)" },
  { value: "it-IT", label: "Italian" },
];

const whisperModelOptions = [
  { value: "auto", label: "Auto", description: "Base-en for English, base for other languages" },
  { value: "tiny", label: "Tiny", description: "Fastest, less accurate" },
  { value: "base", label: "Base", description: "Balanced speed and accuracy" },
  { value: "small", label: "Small", description: "Better accuracy, slower" },
];

function resolveWhisperModel(
  locale: string,
  whisperModel: string,
): "tiny" | "tiny-en" | "base" | "base-en" | "small" | "small-en" {
  const isEnglish = locale.trim().toLowerCase().startsWith("en") || locale.trim() === "";

  switch (whisperModel) {
    case "tiny":
      return isEnglish ? "tiny-en" : "tiny";
    case "base":
      return isEnglish ? "base-en" : "base";
    case "small":
      return isEnglish ? "small-en" : "small";
    case "tiny-en":
      return "tiny-en";
    case "base-en":
      return "base-en";
    case "small-en":
      return "small-en";
    default:
      return isEnglish ? "base-en" : "base";
  }
}

interface SettingsViewProps {
  settings?: AppSettings | null;
  onSettingsChange?: (settings: AppSettings) => void;
}

export function SettingsView({ settings: initialSettings = null, onSettingsChange }: SettingsViewProps) {
  const [settings, setSettings] = useState<AppSettings | null>(initialSettings);
  const [apiKeys, setApiKeys] = useState<ApiKeys | null>(null);
  const [activeTab, setActiveTab] = useState<Tab>("general");
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [kbFileCount, setKbFileCount] = useState<number>(0);
  const [isIndexingKb, setIsIndexingKb] = useState(false);
  const [kbStatus, setKbStatus] = useState<string | null>(null);

  useEffect(() => {
    invoke<ApiKeys>("get_api_keys")
      .then(setApiKeys)
      .catch((err) => setError(String(err)));
  }, []);

  useEffect(() => {
    if (initialSettings) {
      setSettings(initialSettings);
      if (initialSettings.kbFolderPath) {
        countKBFiles(initialSettings.kbFolderPath);
      } else {
        setKbFileCount(0);
      }
      return;
    }

    invoke<AppSettings>("get_settings")
      .then((loadedSettings) => {
        setSettings(loadedSettings);
        if (loadedSettings.kbFolderPath) {
          countKBFiles(loadedSettings.kbFolderPath);
        } else {
          setKbFileCount(0);
        }
      })
      .catch((err) => setError(String(err)));
  }, [initialSettings]);

  useEffect(() => {
    if (settings?.kbFolderPath) {
      syncKnowledgeBase();
    } else {
      setKbStatus(null);
      setIsIndexingKb(false);
    }
  }, [settings?.kbFolderPath]);

  const countKBFiles = async (_path: string) => {
    try {
      setKbFileCount(0);
    } catch {
      setKbFileCount(0);
    }
  };

  const flashSaved = () => {
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  };

  const syncKnowledgeBase = async () => {
    if (!settings?.kbFolderPath) {
      setKbStatus(null);
      setIsIndexingKb(false);
      return;
    }

    try {
      setIsIndexingKb(true);
      setKbStatus("Indexing knowledge base...");
      const addedChunks = await invoke<number>("index_kb");
      setKbStatus(
        addedChunks > 0
          ? `Knowledge base indexed · ${addedChunks} new chunks`
          : "Knowledge base is ready"
      );
      setError(null);
    } catch (err) {
      setKbStatus("Knowledge base indexing failed");
      setError(String(err));
    } finally {
      setIsIndexingKb(false);
    }
  };

  const saveSettings = async (updated: AppSettings) => {
    try {
      await invoke("save_settings", { newSettings: updated });
      setSettings(updated);
      onSettingsChange?.(updated);
      setError(null);
      flashSaved();
    } catch (err) {
      setError(String(err));
    }
  };

  const saveApiKeys = async (updated: ApiKeys) => {
    try {
      await invoke("save_api_keys", { newKeys: updated });
      setApiKeys(updated);
      setError(null);
      flashSaved();
    } catch (err) {
      setError(String(err));
    }
  };

  const chooseFolder = async (key: "kbFolderPath" | "notesFolderPath") => {
    try {
      const selected = await invoke<string | null>("choose_folder");
      if (selected && settings) {
        const updated = { ...settings, [key]: selected };
        await saveSettings(updated);
        if (key === "kbFolderPath") {
          countKBFiles(selected);
        }
      }
    } catch (err) {
      console.error("Failed to choose folder:", err);
    }
  };

  if (!settings || !apiKeys) {
    return (
      <div style={{ padding: spacing[4], color: colors.textMuted }}>
        <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
          <span>Loading settings...</span>
        </div>
      </div>
    );
  }

  const isLocalMode = settings.llmProvider === "ollama" && settings.embeddingProvider === "ollama";

  // Local styles for SettingsView
  const styles = {
    container: {
      padding: spacing[4],
      overflowY: "auto" as const,
      height: "100%",
      backgroundColor: colors.background,
    },
    header: {
      margin: `0 0 ${spacing[4]}px`,
      color: colors.text,
      fontSize: typography.lg,
      fontWeight: 600,
    },
    tabs: {
      display: "flex" as const,
      gap: spacing[1],
      marginBottom: spacing[4],
      borderBottom: `1px solid ${colors.border}`,
      paddingBottom: spacing[1],
    },
    tab: (isActive: boolean): React.CSSProperties => ({
      padding: `${spacing[2]}px ${spacing[3]}px`,
      background: "transparent",
      border: "none",
      borderBottom: isActive ? `2px solid ${colors.accent}` : "2px solid transparent",
      color: isActive ? colors.accent : colors.textSecondary,
      fontSize: typography.base,
      fontWeight: isActive ? 600 : 400,
      cursor: "pointer",
      transition: "all 0.2s",
    }),
    section: {
      marginBottom: spacing[5],
    },
    sectionTitle: {
      color: colors.textSecondary,
      fontSize: typography.xs,
      textTransform: "uppercase" as const,
      letterSpacing: "1.5px",
      margin: `0 0 ${spacing[2]}px`,
      fontWeight: 600,
    },
    sectionDescription: {
      color: colors.textMuted,
      fontSize: typography.sm,
      margin: `0 0 ${spacing[3]}px`,
      lineHeight: 1.5,
    },
    fieldWrap: {
      marginBottom: spacing[3],
    },
    labelStyle: {
      display: "block" as const,
      fontSize: typography.base,
      color: colors.textSecondary,
      marginBottom: spacing[1],
      fontWeight: 500,
    },
    inputStyle: {
      width: "100%",
      padding: `${spacing[2]}px`,
      background: colors.surface,
      color: colors.text,
      border: `1px solid ${colors.border}`,
      borderRadius: 4,
      fontSize: typography.md,
      boxSizing: "border-box" as const,
      fontFamily: "inherit",
    },
    selectStyle: {
      width: "100%",
      padding: `${spacing[2]}px`,
      background: colors.surface,
      color: colors.text,
      border: `1px solid ${colors.border}`,
      borderRadius: 4,
      fontSize: typography.md,
      cursor: "pointer",
    },
    checkboxStyle: {
      display: "flex",
      alignItems: "center",
      gap: spacing[2],
      cursor: "pointer",
    },
    checkboxInput: {
      width: 16,
      height: 16,
      accentColor: colors.accent,
    },
    checkboxLabel: {
      fontSize: typography.base,
      color: colors.text,
    },
    button: {
      padding: `${spacing[2]}px ${spacing[3]}px`,
      background: colors.accent,
      color: colors.textInverse,
      border: "none",
      borderRadius: 4,
      fontSize: typography.base,
      cursor: "pointer",
      transition: "background 0.2s",
    },
    buttonSecondary: {
      padding: `${spacing[2]}px ${spacing[3]}px`,
      background: "transparent",
      color: colors.textSecondary,
      border: `1px solid ${colors.border}`,
      borderRadius: 4,
      fontSize: typography.base,
      cursor: "pointer",
    },
    statusBadge: (type: "success" | "warning" | "error"): React.CSSProperties => ({
      display: "inline-flex",
      alignItems: "center",
      gap: spacing[1],
      padding: `${spacing[1]}px ${spacing[2]}px`,
      background: type === "success" ? `${colors.success}15` : type === "warning" ? `${colors.warning}15` : `${colors.error}15`,
      color: type === "success" ? colors.success : type === "warning" ? colors.warning : colors.error,
      borderRadius: 4,
      fontSize: typography.sm,
    }),
    grid: {
      display: "grid",
      gridTemplateColumns: "1fr 1fr",
      gap: spacing[3],
    },
    aiModeCard: (isSelected: boolean): React.CSSProperties => ({
      padding: spacing[3],
      background: isSelected ? `${colors.accent}10` : colors.surface,
      border: `1px solid ${isSelected ? colors.accent : colors.border}`,
      borderRadius: 8,
      cursor: "pointer",
      transition: "all 0.2s",
    }),
    aiModeTitle: {
      fontSize: typography.md,
      fontWeight: 600,
      color: colors.text,
      marginBottom: spacing[1],
    },
    aiModeDesc: {
      fontSize: typography.sm,
      color: colors.textMuted,
      lineHeight: 1.4,
    },
    divider: {
      height: 1,
      background: colors.border,
      margin: `${spacing[4]}px 0`,
    },
  };

  return (
    <div style={styles.container}>
      <h3 style={styles.header}>Settings</h3>

      {/* Tabs */}
      <div style={styles.tabs}>
        <button
          style={styles.tab(activeTab === "general")}
          onClick={() => setActiveTab("general")}
        >
          General
        </button>
        <button
          style={styles.tab(activeTab === "ai")}
          onClick={() => setActiveTab("ai")}
        >
          AI Providers
        </button>
        <button
          style={styles.tab(activeTab === "advanced")}
          onClick={() => setActiveTab("advanced")}
        >
          Advanced
        </button>
      </div>

      {/* General Tab */}
      {activeTab === "general" && (
        <div>
          {/* Meeting Notes Section */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Meeting Notes</h4>
            <p style={styles.sectionDescription}>
              Where transcripts and generated notes are saved.
            </p>
            <div style={styles.fieldWrap}>
              <label style={styles.labelStyle}>Save Location</label>
              <div style={{ display: "flex", gap: spacing[2] }}>
                <input
                  type="text"
                  value={settings.notesFolderPath}
                  readOnly
                  style={{ ...styles.inputStyle, flex: 1 }}
                  placeholder="Choose a folder..."
                />
                <button
                  style={styles.buttonSecondary}
                  onClick={() => chooseFolder("notesFolderPath")}
                >
                  Choose...
                </button>
              </div>
            </div>
          </div>

          <div style={styles.divider} />

          {/* Knowledge Base Section */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Knowledge Base</h4>
            <p style={styles.sectionDescription}>
              Optional folder of notes for smart suggestions. OpenCassava searches these files during calls to surface relevant talking points.
            </p>
            <div style={styles.fieldWrap}>
              <label style={styles.labelStyle}>KB Folder</label>
              <div style={{ display: "flex", gap: spacing[2], alignItems: "center" }}>
                <input
                  type="text"
                  value={settings.kbFolderPath || ""}
                  readOnly
                  style={{ ...styles.inputStyle, flex: 1 }}
                  placeholder="No folder selected..."
                />
                <button
                  style={styles.buttonSecondary}
                  onClick={() => chooseFolder("kbFolderPath")}
                >
                  {settings.kbFolderPath ? "Change..." : "Choose..."}
                </button>
                {settings.kbFolderPath && (
                  <button
                    style={{ ...styles.buttonSecondary, color: colors.error }}
                    onClick={() => {
                      setKbFileCount(0);
                      setKbStatus(null);
                      saveSettings({ ...settings, kbFolderPath: "" });
                    }}
                  >
                    Clear
                  </button>
                )}
              </div>
              {settings.kbFolderPath && (
                <div style={{ marginTop: spacing[2] }}>
                  <span style={styles.statusBadge("success")}>
                    <span>⚡</span>
                    <span>
                      {isIndexingKb
                        ? "Indexing knowledge base..."
                        : kbStatus || `KB Connected ${kbFileCount > 0 ? `· ${kbFileCount} files` : ""}`}
                    </span>
                  </span>
                </div>
              )}
            </div>
          </div>

          <div style={styles.divider} />

          {/* Privacy Section */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Privacy</h4>
            <label style={styles.checkboxStyle}>
              <input
                type="checkbox"
                checked={settings.hideFromScreenShare}
                onChange={(e) =>
                  saveSettings({ ...settings, hideFromScreenShare: e.target.checked })
                }
                style={styles.checkboxInput}
              />
              <span style={styles.checkboxLabel}>
                Hide from screen sharing
                <span style={{ display: "block", fontSize: typography.sm, color: colors.textMuted, marginTop: 2 }}>
                  Makes the app invisible during screen recordings
                </span>
              </span>
            </label>
          </div>
        </div>
      )}

      {/* AI Providers Tab */}
      {activeTab === "ai" && (
        <div>
          {/* Mode Selection */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>AI Mode</h4>
            <p style={styles.sectionDescription}>
              Choose how OpenCassava processes your data.
            </p>
            <div style={{ display: "flex", flexDirection: "column", gap: spacing[3] }}>
              <div
                style={styles.aiModeCard(isLocalMode)}
                onClick={() =>
                  saveSettings({
                    ...settings,
                    llmProvider: "ollama",
                    embeddingProvider: "ollama",
                  })
                }
              >
                <div style={styles.aiModeTitle}>🔒 Local Mode</div>
                <div style={styles.aiModeDesc}>
                  Everything runs on your machine. Requires Ollama running locally. Maximum privacy, no data leaves your device.
                </div>
              </div>
              <div
                style={styles.aiModeCard(!isLocalMode)}
                onClick={() =>
                  saveSettings({
                    ...settings,
                    llmProvider: "openrouter",
                    embeddingProvider: "voyage",
                  })
                }
              >
                <div style={styles.aiModeTitle}>☁️ Cloud Mode</div>
                <div style={styles.aiModeDesc}>
                  Uses cloud providers for best quality. Requires API keys. Transcription stays local, only text snippets are sent to cloud.
                </div>
              </div>
            </div>
          </div>

          <div style={styles.divider} />

          {/* LLM Provider Settings */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Language Model</h4>
            
            {settings.llmProvider === "openrouter" ? (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>OpenRouter API Key</label>
                  <input
                    type="password"
                    value={apiKeys.openRouterApiKey}
                    onChange={(e) =>
                      saveApiKeys({ ...apiKeys, openRouterApiKey: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="sk-or-..."
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Model</label>
                  <input
                    type="text"
                    value={settings.selectedModel}
                    onChange={(e) =>
                      saveSettings({ ...settings, selectedModel: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="e.g. google/gemini-2.5-flash-preview"
                  />
                  <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
                    Popular: google/gemini-2.5-flash, anthropic/claude-3.5-sonnet, openai/gpt-4o
                  </span>
                </div>
              </>
            ) : settings.llmProvider === "ollama" ? (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Ollama Base URL</label>
                  <input
                    type="text"
                    value={settings.ollamaBaseUrl}
                    onChange={(e) =>
                      saveSettings({ ...settings, ollamaBaseUrl: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="http://127.0.0.1:11434"
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Model</label>
                  <input
                    type="text"
                    value={settings.ollamaLlmModel}
                    onChange={(e) =>
                      saveSettings({ ...settings, ollamaLlmModel: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="e.g. qwen3:8b, llama3.2:3b"
                  />
                </div>
              </>
            ) : (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Base URL</label>
                  <input
                    type="text"
                    value={settings.openAiLlmBaseUrl}
                    onChange={(e) =>
                      saveSettings({ ...settings, openAiLlmBaseUrl: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="http://127.0.0.1:1234"
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>API Key (optional)</label>
                  <input
                    type="password"
                    value={apiKeys.openAiLlmApiKey}
                    onChange={(e) =>
                      saveApiKeys({ ...apiKeys, openAiLlmApiKey: e.target.value })
                    }
                    style={styles.inputStyle}
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Model</label>
                  <input
                    type="text"
                    value={settings.selectedModel}
                    onChange={(e) =>
                      saveSettings({ ...settings, selectedModel: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="e.g. gpt-4o-mini"
                  />
                </div>
              </>
            )}
          </div>

          <div style={styles.divider} />

          {/* Embedding Provider Settings */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Embeddings</h4>
            <p style={styles.sectionDescription}>
              Used for knowledge base search.
            </p>

            {settings.embeddingProvider === "voyage" ? (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Voyage AI API Key</label>
                  <input
                    type="password"
                    value={apiKeys.voyageApiKey}
                    onChange={(e) =>
                      saveApiKeys({ ...apiKeys, voyageApiKey: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="pa-..."
                  />
                </div>
                <div style={{ ...styles.statusBadge("warning"), marginTop: spacing[2] }}>
                  <span>⚡</span>
                  <span>Uses voyage-3-lite model</span>
                </div>
              </>
            ) : settings.embeddingProvider === "ollama" ? (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Ollama Base URL</label>
                  <input
                    type="text"
                    value={settings.ollamaBaseUrl}
                    onChange={(e) =>
                      saveSettings({ ...settings, ollamaBaseUrl: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="http://127.0.0.1:11434"
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Embedding Model</label>
                  <input
                    type="text"
                    value={settings.ollamaEmbedModel}
                    onChange={(e) =>
                      saveSettings({ ...settings, ollamaEmbedModel: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="e.g. nomic-embed-text"
                  />
                </div>
              </>
            ) : (
              <>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Base URL</label>
                  <input
                    type="text"
                    value={settings.openAiEmbedBaseUrl}
                    onChange={(e) =>
                      saveSettings({ ...settings, openAiEmbedBaseUrl: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="http://127.0.0.1:8080"
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>API Key (optional)</label>
                  <input
                    type="password"
                    value={apiKeys.openAiEmbedApiKey}
                    onChange={(e) =>
                      saveApiKeys({ ...apiKeys, openAiEmbedApiKey: e.target.value })
                    }
                    style={styles.inputStyle}
                  />
                </div>
                <div style={styles.fieldWrap}>
                  <label style={styles.labelStyle}>Model</label>
                  <input
                    type="text"
                    value={settings.openAiEmbedModel}
                    onChange={(e) =>
                      saveSettings({ ...settings, openAiEmbedModel: e.target.value })
                    }
                    style={styles.inputStyle}
                    placeholder="e.g. text-embedding-3-small"
                  />
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* Advanced Tab */}
      {activeTab === "advanced" && (
        <div>
          {/* Transcription Section */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Transcription</h4>
            <div style={styles.fieldWrap}>
              <label style={styles.labelStyle}>Language / Locale</label>
              <select
                value={settings.transcriptionLocale}
                onChange={(e) =>
                  saveSettings({ ...settings, transcriptionLocale: e.target.value })
                }
                style={styles.selectStyle}
              >
                {transcriptionLocaleOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
              <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
                OpenCassava will download and use {resolveWhisperModel(settings.transcriptionLocale, settings.whisperModel)} for this language.
              </span>
            </div>
            <div style={styles.fieldWrap}>
              <label style={styles.labelStyle}>Whisper Model</label>
              <select
                value={settings.whisperModel}
                onChange={(e) =>
                  saveSettings({ ...settings, whisperModel: e.target.value })
                }
                style={styles.selectStyle}
              >
                {whisperModelOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
              <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
                {whisperModelOptions.find((option) => option.value === settings.whisperModel)?.description}. Effective model: `{resolveWhisperModel(settings.transcriptionLocale, settings.whisperModel)}`.
              </span>
            </div>
            <div style={styles.fieldWrap}>
              <label style={styles.labelStyle}>Suggestion Cadence</label>
              <input
                type="number"
                min={30}
                step={15}
                value={settings.suggestionIntervalSeconds}
                onChange={(e) =>
                  saveSettings({
                    ...settings,
                    suggestionIntervalSeconds: Math.max(30, Number(e.target.value) || 30),
                  })
                }
                style={styles.inputStyle}
              />
              <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
                Generate suggestions from the recent conversation every N seconds instead of waiting for trigger phrases.
              </span>
            </div>
          </div>

          <div style={styles.divider} />

          {/* Reset Section */}
          <div style={styles.section}>
            <h4 style={styles.sectionTitle}>Reset</h4>
            <button
              style={{ ...styles.buttonSecondary, color: colors.error }}
              onClick={() => {
                if (confirm("Reset all settings to defaults? This cannot be undone.")) {
                  // Reset logic would go here
                }
              }}
            >
              Reset to Defaults
            </button>
          </div>
        </div>
      )}

      {/* Status Messages */}
      {error && (
        <div style={{ ...styles.statusBadge("error"), marginTop: spacing[4] }}>
          <span>⚠️</span>
          <span>{error}</span>
        </div>
      )}
      {saved && (
        <div style={{ ...styles.statusBadge("success"), marginTop: spacing[4] }}>
          <span>✓</span>
          <span>Saved</span>
        </div>
      )}
    </div>
  );
}
