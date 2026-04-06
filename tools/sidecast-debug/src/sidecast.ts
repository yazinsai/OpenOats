import type {
  AppSettings,
  SidecastMessage,
  SidecastResponse,
  GenerationResult,
  FilteredCandidate,
  WebSearchCitation,
} from "./types.ts";
import { INTENSITY_CONFIG, CADENCE_COOLDOWN_SECONDS } from "./types.ts";
import type { ContextWindow } from "./transcript.ts";

// --- State ---
let lastGenerationTime = 0;
let lastSpokenAtByPersona: Record<string, number> = {};
let recentBubbleTexts: string[] = [];
let currentMessages: SidecastMessage[] = [];

export function getMessages(): SidecastMessage[] {
  return currentMessages;
}

export function clearState(): void {
  lastGenerationTime = 0;
  lastSpokenAtByPersona = {};
  recentBubbleTexts = [];
  currentMessages = [];
}

// --- Jaccard Dedup ---
function normalizedWords(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length > 0)
  );
}

function jaccard(a: string, b: string): number {
  const setA = normalizedWords(a);
  const setB = normalizedWords(b);
  if (setA.size === 0 && setB.size === 0) return 1.0;
  let intersection = 0;
  for (const w of setA) {
    if (setB.has(w)) intersection++;
  }
  const union = new Set([...setA, ...setB]).size;
  return intersection / union;
}

// --- Prompt Building ---
function buildPrompt(
  context: ContextWindow,
  settings: AppSettings
): { system: string; user: string } {
  const intensityCfg = INTENSITY_CONFIG[settings.intensity];
  const enabledPersonas = settings.personas.filter((p) => p.isEnabled);

  const personaText = enabledPersonas
    .map(
      (p) =>
        `- id: ${p.id}\n  name: ${p.name}\n  subtitle: ${p.subtitle}\n  prompt: ${p.prompt}\n  verbosity: ${p.verbosity}\n  cadence: ${p.cadence}\n  evidence: ${p.evidencePolicy}`
    )
    .join("\n");

  const system = settings.systemPromptTemplate.replace(
    "{{maxMessagesPerTurn}}",
    String(intensityCfg.maxMessagesPerTurn)
  );

  const user = `Latest utterance:
${context.latestUtterance}

Recent exchange:
${context.recentExchange}

Wider context:
${context.widerContext}

Conversation summary:
${context.conversationSummary}

Open questions:
None

Personas:
${personaText}

Evidence:
No KB evidence retrieved for this turn.`;

  return { system, user };
}

// --- LLM Call ---
const LLM_TIMEOUT_MS = 30_000;

interface LLMResult {
  content: string;
  citations: WebSearchCitation[];
}

async function callLLM(
  system: string,
  user: string,
  settings: AppSettings,
  webSearch: boolean = false
): Promise<LLMResult> {
  let url: string;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  switch (settings.llmProvider) {
    case "openrouter":
      if (!settings.apiKey) throw new Error("OpenRouter API key is not set");
      url = "https://openrouter.ai/api/v1/chat/completions";
      headers["Authorization"] = `Bearer ${settings.apiKey}`;
      headers["HTTP-Referer"] = "OpenOats/SidecastDebug";
      break;
    case "ollama": {
      const base = settings.baseURL.replace(/\/+$/, "");
      if (!base) throw new Error("Ollama base URL is not set");
      url = `${base}/v1/chat/completions`;
      break;
    }
    case "openai-compatible": {
      const base = settings.baseURL.replace(/\/+$/, "");
      if (!base) throw new Error("Base URL is not set");
      url = `${base}/v1/chat/completions`;
      if (settings.apiKey) {
        headers["Authorization"] = `Bearer ${settings.apiKey}`;
      }
      break;
    }
  }

  const body: Record<string, any> = {
    model: settings.model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    max_completion_tokens: settings.maxTokens,
    temperature: settings.temperature,
    stream: false,
  };

  // Add web search plugin for OpenRouter
  if (webSearch && settings.llmProvider === "openrouter") {
    const plugin: Record<string, any> = {
      id: "web",
      max_results: settings.webSearchMaxResults,
    };
    if (settings.webSearchEngine !== "auto") {
      plugin.engine = settings.webSearchEngine;
    }
    body.plugins = [plugin];
    console.log(`[sidecast] web search enabled (engine: ${settings.webSearchEngine}, max: ${settings.webSearchMaxResults})`);
  }

  console.log(`[sidecast] calling ${settings.llmProvider} (${settings.model}) — ${system.length + user.length} chars`);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), LLM_TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err: any) {
    if (err.name === "AbortError") {
      throw new Error(`LLM request timed out after ${LLM_TIMEOUT_MS / 1000}s`);
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`LLM API error (${res.status}): ${text.slice(0, 200)}`);
  }

  const data = await res.json();
  const message = data.choices?.[0]?.message;
  const content: string = message?.content ?? "";

  // Parse citations from OpenRouter annotations
  const citations: WebSearchCitation[] = [];
  if (message?.annotations) {
    for (const ann of message.annotations) {
      if (ann.type === "url_citation" && ann.url_citation) {
        citations.push({
          url: ann.url_citation.url,
          title: ann.url_citation.title ?? "",
          content: ann.url_citation.content,
        });
      }
    }
  }

  return { content, citations };
}

/** Standalone LLM call for summary generation */
export async function llmCall(
  systemPrompt: string,
  userPrompt: string,
  settings: AppSettings
): Promise<string> {
  const result = await callLLM(systemPrompt, userPrompt, settings);
  return result.content;
}

// --- JSON Extraction ---
function extractJSON(text: string): string {
  let s = text.trim();
  if (s.startsWith("```json")) s = s.slice(7);
  else if (s.startsWith("```")) s = s.slice(3);
  if (s.endsWith("```")) s = s.slice(0, -3);
  return s.trim();
}

// --- Filtering ---
function filterAndRank(
  response: SidecastResponse,
  settings: AppSettings,
  currentTime: number
): { accepted: SidecastMessage[]; filtered: FilteredCandidate[] } {
  const intensityCfg = INTENSITY_CONFIG[settings.intensity];
  const personaById = new Map(
    settings.personas.map((p) => [p.id, p])
  );

  const ranked = response.messages
    .filter((m) => m.speak)
    .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));

  const accepted: SidecastMessage[] = [];
  const filtered: FilteredCandidate[] = [];
  const dedupeCorpus = [...recentBubbleTexts];

  for (const candidate of ranked) {
    const persona = personaById.get(candidate.persona_id);
    if (!persona) {
      filtered.push({
        personaName: candidate.persona_id,
        text: candidate.text,
        reason: "Unknown persona ID",
      });
      continue;
    }

    if (accepted.length >= intensityCfg.maxMessagesPerTurn) {
      filtered.push({
        personaName: persona.name,
        text: candidate.text,
        reason: `Intensity cap (max ${intensityCfg.maxMessagesPerTurn})`,
      });
      continue;
    }

    // Cadence cooldown
    if (!intensityCfg.skipPersonaCooldowns) {
      const lastSpoken = lastSpokenAtByPersona[persona.id];
      if (
        lastSpoken !== undefined &&
        currentTime - lastSpoken < CADENCE_COOLDOWN_SECONDS[persona.cadence]
      ) {
        filtered.push({
          personaName: persona.name,
          text: candidate.text,
          reason: `Cadence cooldown (${persona.cadence}: ${CADENCE_COOLDOWN_SECONDS[persona.cadence]}s)`,
        });
        continue;
      }
    }

    // Sanitize text — strip URLs, markdown links, and domain references
    let cleanedText = candidate.text
      .replace(/\[([^\]]*)\]\([^)]+\)/g, "$1")           // [text](url) → text
      .replace(/https?:\/\/\S+/g, "")                    // bare URLs
      .replace(/\b\w+\.(com|org|net|io|ai|app|dev|co|edu|gov)\b/gi, "")  // bare domains
      .replace(/\([^)]*\b(source|via|per|from|according)\b[^)]*\)/gi, "") // (source: ...) parentheticals
      .replace(/\[\s*\]/g, "")                            // leftover empty []
      .replace(/\n/g, " ")
      .replace(/ {2,}/g, " ")
      .replace(/[.,;]\s*$/, "")                           // trailing punctuation from stripped content
      .trim();
    if (cleanedText.length === 0) {
      filtered.push({
        personaName: persona.name,
        text: candidate.text,
        reason: "Empty after sanitization",
      });
      continue;
    }
    // Jaccard dedup
    if (dedupeCorpus.some((prev) => jaccard(prev, cleanedText) > 0.62)) {
      filtered.push({
        personaName: persona.name,
        text: cleanedText,
        reason: "Dedup (Jaccard > 0.62)",
      });
      continue;
    }

    // Evidence policy — skip filter if persona has web search enabled (evidence comes from web)
    if (persona.evidencePolicy === "required" && !persona.webSearchEnabled) {
      filtered.push({
        personaName: persona.name,
        text: cleanedText,
        reason: "Evidence required but none available (no KB, web search off)",
      });
      continue;
    }

    const confidence = Math.max(0, Math.min(1, candidate.confidence ?? 0.55));
    const value = Math.max(0, Math.min(1, candidate.value ?? 0.5));

    // Value gate — drop hollow or low-value responses
    if (value < settings.minValueThreshold) {
      filtered.push({
        personaName: persona.name,
        text: cleanedText,
        reason: `Below value threshold (${value.toFixed(2)} < ${settings.minValueThreshold})`,
      });
      continue;
    }

    const msg: SidecastMessage = {
      id: crypto.randomUUID(),
      personaId: persona.id,
      personaName: persona.name,
      text: cleanedText,
      timestamp: currentTime,
      confidence,
      priority: candidate.priority ?? 0.5,
      value,
    };

    accepted.push(msg);
    dedupeCorpus.push(cleanedText);
  }

  return { accepted, filtered };
}

// --- Main Generate Function ---
export async function generate(
  context: ContextWindow,
  currentTime: number,
  settings: AppSettings
): Promise<GenerationResult> {
  const intensityCfg = INTENSITY_CONFIG[settings.intensity];

  // Cooldown check
  {
    const elapsed = currentTime - lastGenerationTime;
    if (elapsed < intensityCfg.generationCooldownSeconds) {
      return {
        accepted: [],
        filtered: [],
        rawResponse: "(skipped: cooldown)",
        promptCharCount: 0,
        systemPrompt: "",
        userPrompt: "",
        skipped: true,
        citations: [],
        webSearchUsed: false,
      };
    }
  }

  lastGenerationTime = currentTime;

  const { system, user } = buildPrompt(context, settings);
  const promptCharCount = system.length + user.length;

  // Enable web search if any enabled persona has it turned on
  const enabledPersonas = settings.personas.filter((p) => p.isEnabled);
  const webSearch = enabledPersonas.some((p) => p.webSearchEnabled);

  const llmResult = await callLLM(system, user, settings, webSearch);
  const rawResponse = llmResult.content;
  const citations = llmResult.citations;

  let parsed: SidecastResponse;
  try {
    parsed = JSON.parse(extractJSON(rawResponse));
  } catch {
    return {
      accepted: [],
      filtered: [],
      rawResponse,
      promptCharCount,
      systemPrompt: system,
      userPrompt: user,
      skipped: false,
      citations,
      webSearchUsed: webSearch,
    };
  }

  const { accepted, filtered } = filterAndRank(parsed, settings, currentTime);

  // Update state
  if (accepted.length > 0) {
    const msgByPersona = new Map(currentMessages.map((m) => [m.personaId, m]));
    for (const msg of accepted) {
      msgByPersona.set(msg.personaId, msg);
      lastSpokenAtByPersona[msg.personaId] = currentTime;
      recentBubbleTexts.push(msg.text);
    }
    if (recentBubbleTexts.length > 12) {
      recentBubbleTexts = recentBubbleTexts.slice(-12);
    }
    currentMessages = [...msgByPersona.values()].sort((a, b) => {
      if (a.timestamp !== b.timestamp) return b.timestamp - a.timestamp;
      return a.personaName.localeCompare(b.personaName);
    });
  }

  return { accepted, filtered, rawResponse, promptCharCount, systemPrompt: system, userPrompt: user, skipped: false, citations, webSearchUsed: webSearch };
}
