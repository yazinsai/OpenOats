import {
  type AppSettings,
  type SidecastPersona,
  STARTER_PERSONAS,
  DEFAULT_SYSTEM_PROMPT,
} from "./types.ts";

const STORAGE_KEY = "sidecast-debug-settings";

export function loadSettings(): AppSettings {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored) {
    try {
      const parsed = JSON.parse(stored);
      // Merge with defaults to handle new fields added after initial save
      return { ...defaultSettings(), ...parsed };
    } catch {
      // Corrupted, return defaults
    }
  }
  return defaultSettings();
}

export function saveSettings(settings: AppSettings): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
}

function defaultSettings(): AppSettings {
  return {
    llmProvider: "openrouter",
    apiKey: "",
    baseURL: "",
    model: "google/gemini-3.1-flash-lite-preview",
    temperature: 1.0,
    maxTokens: 700,

    windowSize: 20,
    summaryRefreshInterval: 15,

    intensity: "balanced",
    systemPromptTemplate: DEFAULT_SYSTEM_PROMPT,
    minValueThreshold: 0.5,

    webSearchEngine: "auto",
    webSearchMaxResults: 5,

    personas: STARTER_PERSONAS.map((p) => ({ ...p, id: crypto.randomUUID() })),
  };
}

export function addPersona(settings: AppSettings): AppSettings {
  const RANDOM_EMOJI = ["\uD83C\uDFAF", "\uD83D\uDCA1", "\uD83D\uDD2D", "\uD83C\uDFAD", "\uD83E\uDDE0", "\uD83D\uDC41\uFE0F", "\uD83D\uDEE1\uFE0F", "\uD83C\uDFA9"];
  const newPersona: SidecastPersona = {
    id: crypto.randomUUID(),
    name: "New Persona",
    subtitle: "Custom voice",
    prompt:
      "Define what this persona should notice, how it should speak, and when it should stay quiet.",
    avatarTint: "#3b82f6",
    avatarEmoji: RANDOM_EMOJI[Math.floor(Math.random() * RANDOM_EMOJI.length)],
    verbosity: "short",
    cadence: "normal",
    evidencePolicy: "optional",
    isEnabled: true,
    webSearchEnabled: false,
  };
  return { ...settings, personas: [...settings.personas, newPersona] };
}

export function removePersona(
  settings: AppSettings,
  id: string
): AppSettings {
  return {
    ...settings,
    personas: settings.personas.filter((p) => p.id !== id),
  };
}

export function resetPersonas(settings: AppSettings): AppSettings {
  return {
    ...settings,
    personas: STARTER_PERSONAS.map((p) => ({ ...p, id: crypto.randomUUID() })),
  };
}

// --- Export ---

const HEX_TO_TINT: Record<string, string> = {
  "#22c55e": "green",
  "#6366f1": "indigo",
  "#f97316": "orange",
  "#ef4444": "red",
  "#3b82f6": "blue",
  "#64748b": "slate",
  "#14b8a6": "teal",
  "#ec4899": "pink",
};

function hexToTintName(hex: string): string {
  return HEX_TO_TINT[hex.toLowerCase()] ?? "blue";
}

export function exportSettingsJSON(settings: AppSettings): string {
  const payload = {
    version: 1,
    exported_from: "sidecast-debug-tool",
    llmProvider: settings.llmProvider,
    apiKey: settings.apiKey,
    baseURL: settings.baseURL,
    model: settings.model,
    temperature: settings.temperature,
    maxTokens: settings.maxTokens,
    intensity: settings.intensity,
    systemPromptTemplate: settings.systemPromptTemplate,
    minValueThreshold: settings.minValueThreshold,
    windowSize: settings.windowSize,
    summaryRefreshInterval: settings.summaryRefreshInterval,
    webSearchEngine: settings.webSearchEngine,
    webSearchMaxResults: settings.webSearchMaxResults,
    personas: settings.personas.map((p) => ({
      name: p.name,
      subtitle: p.subtitle,
      prompt: p.prompt,
      avatarTint: hexToTintName(p.avatarTint),
      avatarEmoji: p.avatarEmoji || "",
      verbosity: p.verbosity,
      cadence: p.cadence,
      evidencePolicy: p.evidencePolicy,
      isEnabled: p.isEnabled,
      webSearchEnabled: p.webSearchEnabled,
    })),
  };
  return JSON.stringify(payload, null, 2);
}
