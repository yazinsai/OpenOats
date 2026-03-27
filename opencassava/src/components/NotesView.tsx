import { Fragment, useRef, type CSSProperties, type ReactNode, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { EnhancedNotes, MeetingTemplate } from "../types";
import { colors, typography, spacing } from "../theme";

const FALLBACK_TEMPLATES: MeetingTemplate[] = [
  { id: "00000000-0000-0000-0000-000000000000", name: "Summary", icon: "doc.text", system_prompt: "", is_built_in: true },
];

const REGEN_INTERVALS = [
  { value: 30, label: "30s" },
  { value: 60, label: "1 min" },
  { value: 120, label: "2 min" },
  { value: 300, label: "5 min" },
  { value: 600, label: "10 min" },
];

function getPlainTextPreview(markdown: string, length: number): string {
  const withoutCode = markdown.replace(/`[^`]*`/g, "");
  const withoutLinks = withoutCode.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
  const withoutFormatting = withoutLinks.replace(/[*_#>~-]+/g, " ");
  const collapsedWhitespace = withoutFormatting.replace(/\s+/g, " ").trim();
  return collapsedWhitespace.slice(0, length);
}

interface SummarySnapshot {
  timestamp: string;
  markdown: string;
}

interface Props {
  sessionId?: string;
  initialNotes?: EnhancedNotes | null;
  onNotesChange?: (notes: EnhancedNotes | null) => void;
  isRunning?: boolean;
}

type MarkdownBlock =
  | { type: "heading"; level: number; text: string }
  | { type: "paragraph"; text: string }
  | { type: "unordered-list"; items: string[] }
  | { type: "ordered-list"; items: string[] }
  | { type: "blockquote"; lines: string[] }
  | { type: "code"; code: string };

export function NotesView({ sessionId, initialNotes, onNotesChange, isRunning }: Props) {
  const [templates, setTemplates] = useState<MeetingTemplate[]>(FALLBACK_TEMPLATES);
  const [selectedTemplate, setSelectedTemplate] = useState(FALLBACK_TEMPLATES[0].id);
  const [markdown, setMarkdown] = useState("");
  const [isGenerating, setIsGenerating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showThoughts, setShowThoughts] = useState(false);

  // Auto-regenerate state
  const [autoRegen, setAutoRegen] = useState(false);
  const [regenIntervalSec, setRegenIntervalSec] = useState(30);
  const [summaryHistory, setSummaryHistory] = useState<SummarySnapshot[]>([]);
  const [previousMarkdown, setPreviousMarkdown] = useState<string>("");
  const [lastRegenAt, setLastRegenAt] = useState<Date | null>(null);
  const [showHistory, setShowHistory] = useState(false);
  const [historyViewIndex, setHistoryViewIndex] = useState<number | null>(null);
  const [_secondsSinceRegen, setSecondsSinceRegen] = useState<number | null>(null);

  // Refs to avoid stale closures in interval
  const isGeneratingRef = useRef(isGenerating);
  isGeneratingRef.current = isGenerating;
  const markdownRef = useRef(markdown);
  markdownRef.current = markdown;
  const selectedTemplateRef = useRef(selectedTemplate);
  selectedTemplateRef.current = selectedTemplate;
  const sessionIdRef = useRef(sessionId);
  sessionIdRef.current = sessionId;

  // Ref to hold the latest trigger function (avoids stale closures in effects)
  const triggerAutoRegenRef = useRef<() => Promise<void>>(async () => {});
  const autoRegenTrigger = async () => {
    if (isGeneratingRef.current || !sessionIdRef.current) return;
    const currentMarkdown = markdownRef.current;
    if (currentMarkdown) {
      setPreviousMarkdown(currentMarkdown);
      setSummaryHistory((prev) => [
        ...prev.slice(-9),
        { timestamp: new Date().toISOString(), markdown: currentMarkdown },
      ]);
    }
    setMarkdown("");
    setIsGenerating(true);
    setError(null);
    setShowThoughts(false);
    setLastRegenAt(new Date());
    setSecondsSinceRegen(0);
    try {
      await invoke("generate_notes", {
        sessionId: sessionIdRef.current,
        templateId: selectedTemplateRef.current,
      });
      const persistedNotes = await invoke<EnhancedNotes | null>("load_session_notes", {
        id: sessionIdRef.current,
      });
      if (persistedNotes) {
        setMarkdown(persistedNotes.markdown);
        setSelectedTemplate(persistedNotes.template.id);
        onNotesChange?.(persistedNotes);
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setIsGenerating(false);
    }
  };
  triggerAutoRegenRef.current = autoRegenTrigger;

  useEffect(() => {
    invoke<MeetingTemplate[]>("list_templates").then((ts) => {
      if (ts.length > 0) {
        setTemplates(ts);
        setSelectedTemplate((prev) => (ts.some((t) => t.id === prev) ? prev : ts[0].id));
      }
    });
  }, []);

  useEffect(() => {
    const unlisten = listen<string>("notes-chunk", (e) => {
      setMarkdown((prev) => prev + e.payload);
    });
    return () => {
      unlisten.then((f) => f());
    };
  }, []);

  useEffect(() => {
    if (!sessionId) {
      setMarkdown("");
      setSelectedTemplate(templates[0]?.id ?? FALLBACK_TEMPLATES[0].id);
      setError(null);
      setShowThoughts(false);
      setSummaryHistory([]);
      setPreviousMarkdown("");
      setLastRegenAt(null);
      setAutoRegen(false);
      setShowHistory(false);
      setHistoryViewIndex(null);
      return;
    }

    if (initialNotes) {
      setMarkdown(initialNotes.markdown);
      setSelectedTemplate(initialNotes.template.id);
    } else {
      setMarkdown("");
      setSelectedTemplate(templates[0]?.id ?? FALLBACK_TEMPLATES[0].id);
    }

    setError(null);
    setShowThoughts(false);
    setHistoryViewIndex(null);
  }, [sessionId, initialNotes]);

  // Turn off auto-regen when recording stops
  useEffect(() => {
    if (!isRunning) {
      setAutoRegen(false);
    }
  }, [isRunning]);


  // Auto-regen interval
  useEffect(() => {
    if (!autoRegen || !isRunning || !sessionId) return;

    const intervalId = window.setInterval(() => triggerAutoRegenRef.current(), regenIntervalSec * 1000);

    return () => clearInterval(intervalId);
  }, [autoRegen, isRunning, sessionId, regenIntervalSec]);

  // Countdown ticker
  useEffect(() => {
    if (!autoRegen || !isRunning || lastRegenAt === null) return;

    const ticker = window.setInterval(() => {
      setSecondsSinceRegen((s) => (s !== null ? s + 1 : null));
    }, 1000);

    return () => clearInterval(ticker);
  }, [autoRegen, isRunning, lastRegenAt]);

  const handleGenerate = async () => {
    if (!sessionId) return;
    setMarkdown("");
    setIsGenerating(true);
    setError(null);
    setShowThoughts(false);
    try {
      await invoke("generate_notes", { sessionId, templateId: selectedTemplate });
      const persistedNotes = await invoke<EnhancedNotes | null>("load_session_notes", { id: sessionId });
      if (persistedNotes) {
        setMarkdown(persistedNotes.markdown);
        setSelectedTemplate(persistedNotes.template.id);
        onNotesChange?.(persistedNotes);
        setLastRegenAt(new Date());
        setSecondsSinceRegen(0);
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setIsGenerating(false);
    }
  };

  const parsed = parseGeneratedNotes(markdown);
  const displayedMarkdown = isGenerating ? markdown : parsed.visible;

  // Compute new lines for highlighting
  const newLines = previousMarkdown ? computeNewLines(parsed.visible, parseGeneratedNotes(previousMarkdown).visible) : new Set<string>();

  // History view: show a past summary
  const historyEntry = historyViewIndex !== null ? summaryHistory[historyViewIndex] : null;
  const historyParsed = historyEntry ? parseGeneratedNotes(historyEntry.markdown) : null;

  const nextRegenAt =
    autoRegen && isRunning && lastRegenAt !== null
      ? new Date(lastRegenAt.getTime() + regenIntervalSec * 1000)
      : null;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", padding: spacing[4] }}>
      {/* Primary toolbar */}
      <div style={{ display: "flex", gap: spacing[2], marginBottom: spacing[2], flexWrap: "wrap" }}>
        <select
          value={selectedTemplate}
          onChange={(e) => setSelectedTemplate(e.target.value)}
          style={{
            flex: 1,
            minWidth: 120,
            padding: `${spacing[2]}px`,
            background: colors.surface,
            color: colors.text,
            border: `1px solid ${colors.border}`,
            borderRadius: 4,
            fontSize: typography.md,
          }}
        >
          {templates.map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </select>
        <button
          onClick={handleGenerate}
          disabled={isGenerating || !sessionId}
          style={{
            padding: `${spacing[2]}px ${spacing[4]}px`,
            background: colors.accent,
            color: colors.textInverse,
            border: "none",
            borderRadius: 4,
            fontSize: typography.md,
            cursor: isGenerating || !sessionId ? "not-allowed" : "pointer",
            opacity: isGenerating || !sessionId ? 0.5 : 1,
            fontWeight: 500,
          }}
        >
          {isGenerating ? "Generating..." : "Generate Notes"}
        </button>
      </div>

      {/* Auto-regenerate toolbar */}
      {sessionId && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: spacing[2],
            marginBottom: spacing[3],
            padding: `${spacing[2]}px ${spacing[3]}px`,
            background: autoRegen && isRunning ? `${colors.accent}10` : colors.surfaceElevated,
            border: `1px solid ${autoRegen && isRunning ? `${colors.accent}40` : colors.border}`,
            borderRadius: 6,
            flexWrap: "wrap",
          }}
        >
          {/* Toggle */}
          <label
            style={{
              display: "flex",
              alignItems: "center",
              gap: spacing[2],
              cursor: isRunning ? "pointer" : "not-allowed",
              opacity: isRunning ? 1 : 0.5,
              userSelect: "none",
            }}
          >
            <div
              onClick={() => {
                if (!isRunning) return;
                const enabling = !autoRegen;
                setAutoRegen(enabling);
                if (enabling) triggerAutoRegenRef.current();
              }}
              style={{
                width: 36,
                height: 20,
                borderRadius: 10,
                background: autoRegen && isRunning ? colors.accent : colors.border,
                position: "relative",
                transition: "background 0.2s",
                flexShrink: 0,
              }}
            >
              <div
                style={{
                  position: "absolute",
                  top: 2,
                  left: autoRegen && isRunning ? 18 : 2,
                  width: 16,
                  height: 16,
                  borderRadius: "50%",
                  background: colors.textInverse,
                  transition: "left 0.2s",
                  boxShadow: "0 1px 3px rgba(0,0,0,0.2)",
                }}
              />
            </div>
            <span style={{ fontSize: typography.md, color: colors.text, fontWeight: 500 }}>
              Auto-summarize
            </span>
          </label>

          {/* Interval selector */}
          {autoRegen && isRunning && (
            <select
              value={regenIntervalSec}
              onChange={(e) => setRegenIntervalSec(Number(e.target.value))}
              style={{
                padding: `${spacing[1]}px ${spacing[2]}px`,
                background: colors.surface,
                color: colors.text,
                border: `1px solid ${colors.border}`,
                borderRadius: 4,
                fontSize: typography.sm,
              }}
            >
              {REGEN_INTERVALS.map((o) => (
                <option key={o.value} value={o.value}>
                  every {o.label}
                </option>
              ))}
            </select>
          )}

          {/* Status / countdown + force button */}
          <div style={{ flex: 1 }} />
          {autoRegen && isRunning && (
            <>
              <span style={{ fontSize: typography.sm, color: colors.textMuted }}>
                {isGenerating
                  ? "Updating..."
                  : nextRegenAt
                  ? `Next at ${nextRegenAt.toLocaleTimeString()}`
                  : "Starting..."}
              </span>
              <button
                onClick={() => triggerAutoRegenRef.current()}
                disabled={isGenerating}
                style={{
                  padding: `${spacing[1]}px ${spacing[2]}px`,
                  background: "transparent",
                  color: isGenerating ? colors.textMuted : colors.accent,
                  border: `1px solid ${isGenerating ? colors.border : colors.accent}`,
                  borderRadius: 4,
                  cursor: isGenerating ? "not-allowed" : "pointer",
                  fontSize: typography.sm,
                  opacity: isGenerating ? 0.5 : 1,
                }}
              >
                Run now
              </button>
            </>
          )}

          {/* Last updated */}
          {lastRegenAt && (
            <span style={{ fontSize: typography.sm, color: colors.textMuted }}>
              Updated {formatTimeAgo(lastRegenAt)}
            </span>
          )}

          {/* History button */}
          {summaryHistory.length > 0 && (
            <button
              onClick={() => setShowHistory((v) => !v)}
              style={{
                padding: `${spacing[1]}px ${spacing[2]}px`,
                background: "transparent",
                color: showHistory ? colors.accent : colors.textMuted,
                border: `1px solid ${showHistory ? colors.accent : colors.border}`,
                borderRadius: 4,
                cursor: "pointer",
                fontSize: typography.sm,
                display: "flex",
                alignItems: "center",
                gap: 4,
              }}
            >
              History ({summaryHistory.length})
            </button>
          )}

          {/* Not running hint */}
          {!isRunning && (
            <span style={{ fontSize: typography.sm, color: colors.textMuted, fontStyle: "italic" }}>
              Available during active sessions
            </span>
          )}
        </div>
      )}

      {error && (
        <div style={{ color: colors.error, fontSize: typography.md, marginBottom: spacing[2] }}>{error}</div>
      )}

      {/* New-content badge */}
      {!isGenerating && newLines.size > 0 && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: spacing[2],
            padding: `${spacing[1]}px ${spacing[3]}px`,
            background: `${colors.success}12`,
            border: `1px solid ${colors.success}30`,
            borderRadius: 6,
            marginBottom: spacing[2],
            fontSize: typography.sm,
            color: colors.success,
          }}
        >
          <span style={{ fontWeight: 600 }}>New content</span>
          <span style={{ color: colors.textMuted }}>Highlighted in teal below</span>
          <div style={{ flex: 1 }} />
          <button
            onClick={() => setPreviousMarkdown("")}
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: "transparent",
              color: colors.textMuted,
              border: `1px solid ${colors.border}`,
              borderRadius: 4,
              cursor: "pointer",
              fontSize: typography.xs,
            }}
          >
            Dismiss
          </button>
        </div>
      )}

      {!isGenerating && parsed.thoughts && (
        <div style={{ marginBottom: spacing[2], display: "flex", justifyContent: "flex-end" }}>
          <button
            onClick={() => setShowThoughts((prev) => !prev)}
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: "transparent",
              color: colors.textMuted,
              border: `1px solid ${colors.border}`,
              borderRadius: 4,
              cursor: "pointer",
              fontSize: typography.sm,
            }}
          >
            {showThoughts ? "Hide Thought" : "Show Thought"}
          </button>
        </div>
      )}

      {/* Main content area: history panel + notes */}
      <div style={{ flex: 1, overflow: "hidden", display: "flex", gap: spacing[3] }}>
        {/* History side panel */}
        {showHistory && summaryHistory.length > 0 && (
          <div
            style={{
              width: 200,
              flexShrink: 0,
              display: "flex",
              flexDirection: "column",
              border: `1px solid ${colors.border}`,
              borderRadius: 6,
              overflow: "hidden",
              background: colors.surface,
            }}
          >
            <div
              style={{
                padding: `${spacing[2]}px ${spacing[3]}px`,
                borderBottom: `1px solid ${colors.border}`,
                fontSize: typography.sm,
                fontWeight: 600,
                color: colors.textSecondary,
                background: colors.surfaceElevated,
              }}
            >
              Previous Summaries
            </div>
            <div style={{ flex: 1, overflowY: "auto" }}>
              {summaryHistory
                .slice()
                .reverse()
                .map((entry, reversedIdx) => {
                  const idx = summaryHistory.length - 1 - reversedIdx;
                  const isSelected = historyViewIndex === idx;
                  return (
                    <button
                      key={idx}
                      onClick={() => setHistoryViewIndex(isSelected ? null : idx)}
                      style={{
                        width: "100%",
                        textAlign: "left",
                        padding: `${spacing[2]}px ${spacing[3]}px`,
                        background: isSelected ? `${colors.accent}15` : "transparent",
                        border: "none",
                        borderBottom: `1px solid ${colors.border}`,
                        cursor: "pointer",
                        color: isSelected ? colors.accent : colors.textSecondary,
                      }}
                    >
                      <div style={{ fontSize: typography.sm, fontWeight: isSelected ? 600 : 400 }}>
                        {formatHistoryTime(entry.timestamp)}
                      </div>
                      <div
                        style={{
                          fontSize: typography.xs,
                          color: colors.textMuted,
                          marginTop: 2,
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {getPlainTextPreview(entry.markdown, 60)}
                      </div>
                    </button>
                  );
                })}
            </div>
          </div>
        )}

        {/* Notes / history-entry view */}
        <div style={{ flex: 1, overflowY: "auto" }}>
          {historyViewIndex !== null && historyParsed ? (
            // Viewing a history entry
            <div>
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: spacing[2],
                  marginBottom: spacing[3],
                  padding: `${spacing[2]}px ${spacing[3]}px`,
                  background: `${colors.warning}10`,
                  border: `1px solid ${colors.warning}30`,
                  borderRadius: 6,
                  fontSize: typography.sm,
                  color: colors.warning,
                }}
              >
                <span>Viewing snapshot from {formatHistoryTime(summaryHistory[historyViewIndex].timestamp)}</span>
                <div style={{ flex: 1 }} />
                <button
                  onClick={() => setHistoryViewIndex(null)}
                  style={{
                    padding: `${spacing[1]}px ${spacing[2]}px`,
                    background: "transparent",
                    color: colors.warning,
                    border: `1px solid ${colors.warning}50`,
                    borderRadius: 4,
                    cursor: "pointer",
                    fontSize: typography.xs,
                  }}
                >
                  Back to current
                </button>
              </div>
              <MarkdownPreview markdown={historyParsed.visible} newLines={new Set()} />
            </div>
          ) : displayedMarkdown ? (
            <div>
              <MarkdownPreview markdown={displayedMarkdown} newLines={isGenerating ? new Set() : newLines} />
              {!isGenerating && showThoughts && parsed.thoughts && (
                <div style={{ marginTop: spacing[4], borderTop: `1px solid ${colors.border}`, paddingTop: spacing[3] }}>
                  <div
                    style={{
                      color: colors.textMuted,
                      fontSize: typography.xs,
                      marginBottom: spacing[2],
                      textTransform: "uppercase",
                      letterSpacing: "1px",
                      fontWeight: 600,
                    }}
                  >
                    Thought
                  </div>
                  <pre
                    style={{
                      fontSize: typography.sm,
                      color: colors.textSecondary,
                      whiteSpace: "pre-wrap",
                      lineHeight: 1.6,
                      margin: 0,
                    }}
                  >
                    {parsed.thoughts}
                  </pre>
                </div>
              )}
            </div>
          ) : (
            <div
              style={{
                flex: 1,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                color: colors.textMuted,
                fontSize: typography.md,
                height: "100%",
              }}
            >
              {sessionId ? "Select a template and click Generate Notes" : "Start a session to generate notes"}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function computeNewLines(current: string, previous: string): Set<string> {
  if (!previous) return new Set();
  const prevLines = new Set(
    previous
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean),
  );
  const result = new Set<string>();
  current
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .forEach((line) => {
      if (!prevLines.has(line)) result.add(line);
    });
  return result;
}

function formatTimeAgo(date: Date): string {
  const secs = Math.floor((Date.now() - date.getTime()) / 1000);
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  return `${Math.floor(mins / 60)}h ago`;
}

function formatHistoryTime(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function parseGeneratedNotes(markdown: string): { visible: string; thoughts: string | null } {
  if (!markdown) {
    return { visible: "", thoughts: null };
  }

  const thoughtMatch = markdown.match(/<think>([\s\S]*?)<\/think>/i);
  const thoughts = thoughtMatch?.[1]?.trim() || null;

  const visible = markdown
    .replace(/<think>[\s\S]*?<\/think>/gi, "")
    .replace(/<\|begin_of_box\|>/gi, "")
    .replace(/<\|end_of_box\|>/gi, "")
    .trim();

  return { visible, thoughts };
}

// ─── Markdown Renderer ───────────────────────────────────────────────────────

function MarkdownPreview({ markdown, newLines }: { markdown: string; newLines: Set<string> }) {
  const blocks = parseMarkdownBlocks(markdown);
  return (
    <div style={{ color: colors.text, fontSize: typography.md, lineHeight: 1.65 }}>
      {blocks.map((block, idx) => renderBlock(block, idx, newLines))}
    </div>
  );
}

function isBlockNew(block: MarkdownBlock, newLines: Set<string>): boolean {
  if (newLines.size === 0) return false;
  switch (block.type) {
    case "heading":
      return newLines.has(block.text.trim()) || newLines.has(`${"#".repeat(block.level)} ${block.text}`.trim());
    case "paragraph":
      return newLines.has(block.text.trim());
    case "unordered-list":
    case "ordered-list":
      return block.items.some((item) => newLines.has(item.trim()));
    case "blockquote":
      return block.lines.some((line) => newLines.has(line.trim()));
    case "code":
      return newLines.has(block.code.trim());
    default:
      return false;
  }
}

function parseMarkdownBlocks(markdown: string): MarkdownBlock[] {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const blocks: MarkdownBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();

    if (!trimmed) {
      index += 1;
      continue;
    }

    if (trimmed.startsWith("```")) {
      index += 1;
      const codeLines: string[] = [];

      while (index < lines.length && !lines[index].trim().startsWith("```")) {
        codeLines.push(lines[index]);
        index += 1;
      }

      if (index < lines.length) {
        index += 1;
      }

      blocks.push({ type: "code", code: codeLines.join("\n") });
      continue;
    }

    const headingMatch = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (headingMatch) {
      blocks.push({ type: "heading", level: headingMatch[1].length, text: headingMatch[2] });
      index += 1;
      continue;
    }

    if (/^[-*]\s+/.test(trimmed)) {
      const items: string[] = [];

      while (index < lines.length) {
        const match = lines[index].trim().match(/^[-*]\s+(.*)$/);
        if (!match) break;
        items.push(match[1]);
        index += 1;
      }

      blocks.push({ type: "unordered-list", items });
      continue;
    }

    if (/^\d+\.\s+/.test(trimmed)) {
      const items: string[] = [];

      while (index < lines.length) {
        const match = lines[index].trim().match(/^\d+\.\s+(.*)$/);
        if (!match) break;
        items.push(match[1]);
        index += 1;
      }

      blocks.push({ type: "ordered-list", items });
      continue;
    }

    if (trimmed.startsWith(">")) {
      const quoteLines: string[] = [];

      while (index < lines.length) {
        const current = lines[index].trim();
        if (!current.startsWith(">")) break;
        quoteLines.push(current.replace(/^>\s?/, ""));
        index += 1;
      }

      blocks.push({ type: "blockquote", lines: quoteLines });
      continue;
    }

    const paragraphLines: string[] = [];

    while (index < lines.length) {
      const currentTrimmed = lines[index].trim();
      if (!currentTrimmed) break;
      if (
        currentTrimmed.startsWith("```") ||
        /^(#{1,6})\s+/.test(currentTrimmed) ||
        /^[-*]\s+/.test(currentTrimmed) ||
        /^\d+\.\s+/.test(currentTrimmed) ||
        currentTrimmed.startsWith(">")
      ) {
        break;
      }
      paragraphLines.push(currentTrimmed);
      index += 1;
    }

    blocks.push({ type: "paragraph", text: paragraphLines.join(" ") });
  }

  return blocks;
}

function renderBlock(block: MarkdownBlock, index: number, newLines: Set<string>) {
  const isNew = isBlockNew(block, newLines);
  const newStyle: CSSProperties = isNew
    ? {
        borderLeft: `3px solid ${colors.accent}`,
        paddingLeft: spacing[3],
        background: `${colors.accent}08`,
        borderRadius: "0 4px 4px 0",
        marginLeft: -spacing[3] - 3,
      }
    : {};

  switch (block.type) {
    case "heading": {
      const sizeMap: Record<number, number> = {
        1: typography["3xl"],
        2: typography["2xl"],
        3: typography.xl,
        4: typography.lg,
        5: typography.md,
        6: typography.md,
      };

      return (
        <div
          key={`heading-${index}`}
          style={{
            fontSize: sizeMap[block.level] ?? typography.md,
            fontWeight: 700,
            color: isNew ? colors.accent : colors.text,
            marginTop: index === 0 ? 0 : spacing[4],
            marginBottom: spacing[2],
            letterSpacing: block.level <= 2 ? "-0.02em" : "normal",
            ...newStyle,
          }}
        >
          {renderInlineMarkdown(block.text)}
          {isNew && (
            <span
              style={{
                marginLeft: spacing[2],
                fontSize: typography.xs,
                fontWeight: 600,
                color: colors.accent,
                background: `${colors.accent}20`,
                padding: "1px 6px",
                borderRadius: 10,
                verticalAlign: "middle",
                textTransform: "uppercase",
                letterSpacing: "0.5px",
              }}
            >
              new
            </span>
          )}
        </div>
      );
    }
    case "paragraph":
      return (
        <p
          key={`paragraph-${index}`}
          style={{ margin: `0 0 ${spacing[3]}px`, color: isNew ? colors.text : colors.textSecondary, ...newStyle }}
        >
          {renderInlineMarkdown(block.text)}
        </p>
      );
    case "unordered-list":
      return renderList(block.items, index, false, newLines);
    case "ordered-list":
      return renderList(block.items, index, true, newLines);
    case "blockquote":
      return (
        <blockquote
          key={`blockquote-${index}`}
          style={{
            margin: `0 0 ${spacing[3]}px`,
            padding: `${spacing[2]}px ${spacing[3]}px`,
            borderLeft: `3px solid ${isNew ? colors.accent : colors.accent}`,
            background: isNew ? `${colors.accent}12` : colors.accentMuted,
            color: colors.textSecondary,
            borderRadius: 6,
          }}
        >
          {block.lines.map((line, lineIndex) => (
            <p key={lineIndex} style={{ margin: lineIndex === block.lines.length - 1 ? 0 : `0 0 ${spacing[2]}px` }}>
              {renderInlineMarkdown(line)}
            </p>
          ))}
        </blockquote>
      );
    case "code":
      return (
        <pre
          key={`code-${index}`}
          style={{
            margin: `0 0 ${spacing[3]}px`,
            padding: `${spacing[3]}px`,
            whiteSpace: "pre-wrap",
            overflowX: "auto",
            background: isNew ? `${colors.accent}08` : colors.surfaceElevated,
            border: `1px solid ${isNew ? `${colors.accent}40` : colors.border}`,
            borderRadius: 8,
            color: colors.text,
            fontSize: typography.sm,
            lineHeight: 1.6,
          }}
        >
          <code>{block.code}</code>
        </pre>
      );
  }
}

function renderList(items: string[], index: number, ordered: boolean, newLines: Set<string>) {
  const listStyle: CSSProperties = {
    margin: `0 0 ${spacing[3]}px`,
    paddingLeft: spacing[4] + spacing[2],
    color: colors.textSecondary,
  };

  const ListTag = ordered ? "ol" : "ul";
  return (
    <ListTag key={`${ordered ? "ordered" : "unordered"}-${index}`} style={listStyle}>
      {items.map((item, itemIndex) => {
        const isItemNew = newLines.size > 0 && newLines.has(item.trim());
        return (
          <li
            key={itemIndex}
            style={{
              marginBottom: spacing[1],
              color: isItemNew ? colors.text : colors.textSecondary,
              background: isItemNew ? `${colors.accent}10` : "transparent",
              borderRadius: isItemNew ? 3 : 0,
              padding: isItemNew ? `1px ${spacing[1]}px` : undefined,
            }}
          >
            {renderInlineMarkdown(item)}
            {isItemNew && (
              <span
                style={{
                  marginLeft: spacing[1],
                  fontSize: typography.xs,
                  fontWeight: 600,
                  color: colors.accent,
                  verticalAlign: "middle",
                }}
              >
                ●
              </span>
            )}
          </li>
        );
      })}
    </ListTag>
  );
}

function renderInlineMarkdown(text: string): ReactNode[] {
  const tokens = text
    .split(/(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]+\]\([^)]+\))/g)
    .filter(Boolean);

  return tokens.map((token, index) => {
    if (token.startsWith("`") && token.endsWith("`")) {
      return (
        <code
          key={index}
          style={{
            background: colors.surfaceElevated,
            border: `1px solid ${colors.border}`,
            borderRadius: 4,
            padding: "1px 5px",
            fontSize: typography.sm,
            color: colors.text,
          }}
        >
          {token.slice(1, -1)}
        </code>
      );
    }

    if (token.startsWith("**") && token.endsWith("**")) {
      return (
        <strong key={index} style={{ color: colors.text }}>
          {token.slice(2, -2)}
        </strong>
      );
    }

    if (token.startsWith("*") && token.endsWith("*")) {
      return <em key={index}>{token.slice(1, -1)}</em>;
    }

    const linkMatch = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (linkMatch) {
      return (
        <a
          key={index}
          href={linkMatch[2]}
          target="_blank"
          rel="noreferrer"
          style={{ color: colors.accent, textDecoration: "none", borderBottom: `1px solid ${colors.accent}55` }}
        >
          {linkMatch[1]}
        </a>
      );
    }

    return <Fragment key={index}>{token}</Fragment>;
  });
}
