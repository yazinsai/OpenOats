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

    contextMode: "window",
    windowSize: 20,
    summaryRefreshInterval: 15,
    fullModeCharLimit: 4000,

    intensity: "balanced",
    systemPromptTemplate: DEFAULT_SYSTEM_PROMPT,
    forceFire: false,

    personas: STARTER_PERSONAS.map((p) => ({ ...p, id: crypto.randomUUID() })),
  };
}

export function addPersona(settings: AppSettings): AppSettings {
  const newPersona: SidecastPersona = {
    id: crypto.randomUUID(),
    name: "New Persona",
    subtitle: "Custom voice",
    prompt:
      "Define what this persona should notice, how it should speak, and when it should stay quiet.",
    avatarTint: "#3b82f6",
    verbosity: "short",
    cadence: "normal",
    evidencePolicy: "optional",
    isEnabled: true,
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
