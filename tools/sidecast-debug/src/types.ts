// --- Transcript ---

export interface TranscriptSegment {
  start: number; // seconds
  duration: number;
  text: string;
}

// --- Personas ---

export type PersonaVerbosity = "terse" | "short" | "medium";
export type PersonaCadence = "rare" | "normal" | "active";
export type PersonaEvidencePolicy = "required" | "preferred" | "optional";

export const CADENCE_COOLDOWN_SECONDS: Record<PersonaCadence, number> = {
  rare: 40,
  normal: 24,
  active: 14,
};

export interface SidecastPersona {
  id: string;
  name: string;
  subtitle: string;
  prompt: string;
  avatarTint: string;
  verbosity: PersonaVerbosity;
  cadence: PersonaCadence;
  evidencePolicy: PersonaEvidencePolicy;
  isEnabled: boolean;
  webSearchEnabled: boolean;
}

// --- Sidecast Messages ---

export interface SidecastMessage {
  id: string;
  personaId: string;
  personaName: string;
  text: string;
  timestamp: number;
  confidence: number;
  priority: number;
  value: number;
}

export interface SidecastResponseMessage {
  persona_id: string;
  speak: boolean;
  text: string;
  priority: number | null;
  confidence: number | null;
  value: number | null;
}

export interface SidecastResponse {
  messages: SidecastResponseMessage[];
}

// --- Filter Debug Info ---

export interface FilteredCandidate {
  personaName: string;
  text: string;
  reason: string;
}

export interface GenerationResult {
  accepted: SidecastMessage[];
  filtered: FilteredCandidate[];
  rawResponse: string;
  promptCharCount: number;
  systemPrompt: string;
  userPrompt: string;
  skipped: boolean;
  citations: WebSearchCitation[];
  webSearchUsed: boolean;
}

export interface DebugLogEntry {
  id: number;
  timestamp: number;       // video time in seconds
  wallTime: Date;
  result: GenerationResult;
}

// --- Settings ---

export type LLMProvider = "openrouter" | "ollama" | "openai-compatible";
export type WebSearchEngine = "auto" | "native" | "exa" | "parallel" | "firecrawl";

export interface WebSearchCitation {
  url: string;
  title: string;
  content?: string;
}
export type SidecastIntensity = "quiet" | "balanced" | "lively";

export const INTENSITY_CONFIG: Record<
  SidecastIntensity,
  {
    maxMessagesPerTurn: number;
    generationCooldownSeconds: number;
    skipPersonaCooldowns: boolean;
  }
> = {
  quiet: {
    maxMessagesPerTurn: 1,
    generationCooldownSeconds: 90,
    skipPersonaCooldowns: false,
  },
  balanced: {
    maxMessagesPerTurn: 2,
    generationCooldownSeconds: 60,
    skipPersonaCooldowns: false,
  },
  lively: {
    maxMessagesPerTurn: 10,
    generationCooldownSeconds: 0,
    skipPersonaCooldowns: true,
  },
};

export interface AppSettings {
  // LLM
  llmProvider: LLMProvider;
  apiKey: string;
  baseURL: string;
  model: string;
  temperature: number;
  maxTokens: number;

  // Context
  windowSize: number;
  summaryRefreshInterval: number;

  // Sidecast
  intensity: SidecastIntensity;
  systemPromptTemplate: string;
  forceFire: boolean;

  // Quality
  minValueThreshold: number;

  // Web Search
  webSearchEngine: WebSearchEngine;
  webSearchMaxResults: number;

  // Personas
  personas: SidecastPersona[];
}

export const STARTER_PERSONAS: SidecastPersona[] = [
  {
    id: crypto.randomUUID(),
    name: "The Checker",
    subtitle: "Facts and missing nuance",
    prompt:
      "Verify claims, spot weak assumptions, and correct timing, numbers, or framing. Stay calm and precise.",
    avatarTint: "#22c55e",
    verbosity: "short",
    cadence: "normal",
    evidencePolicy: "required",
    isEnabled: true,
    webSearchEnabled: true,
  },
  {
    id: crypto.randomUUID(),
    name: "The Archivist",
    subtitle: "Context and precedent",
    prompt:
      "Add useful background, comparisons, history, or precedent that helps the host understand what was just said.",
    avatarTint: "#6366f1",
    verbosity: "short",
    cadence: "normal",
    evidencePolicy: "preferred",
    isEnabled: true,
    webSearchEnabled: true,
  },
  {
    id: crypto.randomUUID(),
    name: "The Sniper",
    subtitle: "Punchy one-liners",
    prompt:
      "Write short, sharp, host-usable punch lines or callbacks. Prioritize timing and brevity over explanation.",
    avatarTint: "#f97316",
    verbosity: "terse",
    cadence: "rare",
    evidencePolicy: "optional",
    isEnabled: true,
    webSearchEnabled: false,
  },
  {
    id: crypto.randomUUID(),
    name: "The Menace",
    subtitle: "Skeptic and chaos",
    prompt:
      "Inject pointed skepticism or contrarian heat without becoming abusive or unusably toxic. Make the tension entertaining.",
    avatarTint: "#ef4444",
    verbosity: "terse",
    cadence: "rare",
    evidencePolicy: "optional",
    isEnabled: true,
    webSearchEnabled: false,
  },
];

export const DEFAULT_SYSTEM_PROMPT = `You are Sidecast, a live multi-persona producer for a host-assist sidebar.
Decide which personas should speak right now in response to the latest utterance.

Quality bar:
- Only speak when you have genuine insight — a non-obvious fact, a sharp reframe, a useful correction, or a punchy callback.
- Silence is better than filler. If nothing clears the bar, return {"messages":[]}.
- Every bubble should make the host think "glad I saw that." If it wouldn't, don't send it.

Rules:
- Return valid JSON only.
- Use at most {{maxMessagesPerTurn}} persona messages.
- Never include URLs, links, citations, or source references in the text. The text is the insight itself, nothing else.
- No markdown, no emoji, no stage directions, no quotes around the text.
- Keep text extremely dense — every word must earn its place.
- Fact-heavy personas must stay careful and avoid fabricated certainty. Use web search context when available.
- Humor and chaos personas can be sharp, but never hateful or unusably toxic.
- Set priority (0.0–1.0) honestly: 0.9+ means "the host needs to see this right now." Most messages should be 0.4–0.7.
- Set confidence (0.0–1.0) based on how sure you are the claim is correct. Below 0.5 means you're guessing.
- Set value (0.0–1.0): how much this message would genuinely help the host. Be brutally honest.
  0.0–0.3: generic, obvious, or hollow — anyone could say this. Do not send.
  0.4–0.5: mildly interesting but not actionable.
  0.6–0.7: solid insight the host probably didn't know or hadn't considered.
  0.8–1.0: genuinely surprising, corrects a misconception, or provides a killer reframe.

Output schema:
{"messages":[{"persona_id":"UUID","speak":true,"text":"string","priority":0.0,"confidence":0.0,"value":0.0}]}`;

