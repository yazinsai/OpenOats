import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { ApiKeys, AppSettings } from "../types";

const sectionTitle: React.CSSProperties = {
  color: "#888",
  fontSize: 12,
  textTransform: "uppercase",
  margin: "0 0 8px",
};

const fieldWrap: React.CSSProperties = { marginBottom: 12 };

const labelStyle: React.CSSProperties = {
  display: "block",
  fontSize: 12,
  color: "#888",
  marginBottom: 4,
};

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "4px 8px",
  background: "#1a1a1a",
  color: "#fff",
  border: "1px solid #444",
  borderRadius: 4,
  fontSize: 13,
  boxSizing: "border-box",
};

export function SettingsView() {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [apiKeys, setApiKeys] = useState<ApiKeys | null>(null);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([
      invoke<AppSettings>("get_settings"),
      invoke<ApiKeys>("get_api_keys"),
    ])
      .then(([loadedSettings, loadedKeys]) => {
        setSettings(loadedSettings);
        setApiKeys(loadedKeys);
      })
      .catch((err) => setError(String(err)));
  }, []);

  if (!settings || !apiKeys) {
    return <div style={{ padding: 16, color: "#666" }}>Loading settings...</div>;
  }

  const flashSaved = () => {
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  };

  const saveSettings = async (updated: AppSettings) => {
    try {
      await invoke("save_settings", { newSettings: updated });
      setSettings(updated);
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

  const textField = (
    label: string,
    value: string,
    key: keyof AppSettings,
    type = "text",
    placeholder?: string,
  ) => (
    <div style={fieldWrap}>
      <label style={labelStyle}>{label}</label>
      <input
        type={type}
        value={value}
        placeholder={placeholder}
        onChange={(e) => saveSettings({ ...settings, [key]: e.target.value })}
        style={inputStyle}
      />
    </div>
  );

  const secretField = (
    label: string,
    value: string,
    key: keyof ApiKeys,
    placeholder?: string,
  ) => (
    <div style={fieldWrap}>
      <label style={labelStyle}>{label}</label>
      <input
        type="password"
        value={value}
        placeholder={placeholder}
        onChange={(e) => saveApiKeys({ ...apiKeys, [key]: e.target.value })}
        style={inputStyle}
      />
    </div>
  );

  const selectField = (
    label: string,
    value: string,
    key: keyof AppSettings,
    options: Array<{ value: string; label: string }>,
  ) => (
    <div style={fieldWrap}>
      <label style={labelStyle}>{label}</label>
      <select
        value={value}
        onChange={(e) => saveSettings({ ...settings, [key]: e.target.value })}
        style={inputStyle}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </div>
  );

  return (
    <div style={{ padding: 16, overflowY: "auto", height: "100%" }}>
      <h3 style={{ margin: "0 0 16px", color: "#ccc" }}>Settings</h3>

      <section style={{ marginBottom: 20 }}>
        <h4 style={sectionTitle}>LLM</h4>
        {selectField("Provider", settings.llmProvider, "llmProvider", [
          { value: "openrouter", label: "OpenRouter" },
          { value: "ollama", label: "Ollama-Compatible" },
          { value: "openai", label: "OpenAI Compatible" },
        ])}

        {settings.llmProvider === "openrouter" && (
          <>
            {secretField("OpenRouter API Key", apiKeys.openRouterApiKey, "openRouterApiKey")}
            {textField("Model", settings.selectedModel, "selectedModel", "text", "e.g. google/gemini-2.5-flash-preview")}
          </>
        )}

        {settings.llmProvider === "ollama" && (
          <>
            {textField("Base URL", settings.ollamaBaseUrl, "ollamaBaseUrl", "text", "http://127.0.0.1:11434")}
            {textField("Model", settings.ollamaLlmModel, "ollamaLlmModel", "text", "e.g. qwen3:8b")}
          </>
        )}

        {settings.llmProvider === "openai" && (
          <>
            {textField("Base URL", settings.openAiLlmBaseUrl, "openAiLlmBaseUrl", "text", "http://127.0.0.1:1234")}
            {secretField("API Key (optional)", apiKeys.openAiLlmApiKey, "openAiLlmApiKey")}
            {textField("Model", settings.selectedModel, "selectedModel", "text", "e.g. nvidia/nemotron-3-nano-4b")}
          </>
        )}
      </section>

      <section style={{ marginBottom: 20 }}>
        <h4 style={sectionTitle}>Embeddings</h4>
        {selectField("Provider", settings.embeddingProvider, "embeddingProvider", [
          { value: "voyage", label: "Voyage AI" },
          { value: "ollama", label: "Ollama-Compatible" },
          { value: "openai", label: "OpenAI Compatible" },
        ])}

        {settings.embeddingProvider === "voyage" && (
          <>
            {secretField("Voyage API Key", apiKeys.voyageApiKey, "voyageApiKey")}
            <div style={{ ...labelStyle, marginTop: -4, marginBottom: 8 }}>
              Uses the built-in `voyage-3-lite` model.
            </div>
          </>
        )}

        {settings.embeddingProvider === "ollama" && (
          <>
            {textField("Base URL", settings.ollamaBaseUrl, "ollamaBaseUrl", "text", "http://127.0.0.1:11434")}
            {textField("Embedding Model", settings.ollamaEmbedModel, "ollamaEmbedModel", "text", "e.g. nomic-embed-text")}
          </>
        )}

        {settings.embeddingProvider === "openai" && (
          <>
            {textField("Base URL", settings.openAiEmbedBaseUrl, "openAiEmbedBaseUrl", "text", "http://127.0.0.1:1234")}
            {secretField("API Key (optional)", apiKeys.openAiEmbedApiKey, "openAiEmbedApiKey")}
            {textField("Embedding Model", settings.openAiEmbedModel, "openAiEmbedModel", "text", "e.g. text-embedding-3-small")}
          </>
        )}
      </section>

      <section style={{ marginBottom: 20 }}>
        <h4 style={sectionTitle}>Transcription</h4>
        {textField("Locale (e.g. en-US)", settings.transcriptionLocale, "transcriptionLocale")}
      </section>

      <section style={{ marginBottom: 20 }}>
        <h4 style={sectionTitle}>Knowledge Base</h4>
        {textField("KB Folder Path", settings.kbFolderPath ?? "", "kbFolderPath")}
        {textField("Notes Folder Path", settings.notesFolderPath, "notesFolderPath")}
      </section>

      {error && <div style={{ color: "#e74c3c", fontSize: 13, marginTop: 8 }}>{error}</div>}
      {saved && <div style={{ color: "#27ae60", fontSize: 13, marginTop: 8 }}>Saved</div>}
    </div>
  );
}
