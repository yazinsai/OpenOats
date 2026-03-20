export interface Utterance {
  id: string;
  text: string;
  speaker: "you" | "them";
  timestamp: string;
}

export interface Suggestion {
  id: string;
  kind: "knowledge_base" | "smart_question";
  text: string;
  timestamp: string;
  kbHits: KBResult[];
}

export interface KBResult {
  id: string;
  text: string;
  sourceFile: string;
  score: number;
}

export interface AppSettings {
  selectedModel: string;
  transcriptionLocale: string;
  transcriptionModel: string;
  whisperModel: string;
  inputDeviceName: string | null;
  systemAudioDeviceName: string | null;
  llmProvider: string;
  embeddingProvider: string;
  ollamaBaseUrl: string;
  ollamaLlmModel: string;
  ollamaEmbedModel: string;
  openAiLlmBaseUrl: string;
  openAiEmbedBaseUrl: string;
  openAiEmbedModel: string;
  suggestionIntervalSeconds: number;
  kbFolderPath: string | null;
  notesFolderPath: string;
  hasAcknowledgedRecordingConsent: boolean;
  hideFromScreenShare: boolean;
  hasCompletedOnboarding: boolean;
}

export interface ApiKeys {
  openRouterApiKey: string;
  voyageApiKey: string;
  openAiLlmApiKey: string;
  openAiEmbedApiKey: string;
}

export interface SessionRecord {
  id: string;
  startedAt: string;
  endedAt: string | null;
  utteranceCount: number;
  hasNotes: boolean;
  title: string | null;
}

export interface TemplateSnapshot {
  id: string;
  name: string;
  icon: string;
  systemPrompt?: string;
  system_prompt?: string;
}

export interface EnhancedNotes {
  template: TemplateSnapshot;
  generatedAt?: string;
  generated_at?: string;
  markdown: string;
}

export interface SessionDetails {
  transcript: Utterance[];
  notes: EnhancedNotes | null;
}
