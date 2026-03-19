import { Fragment, type CSSProperties, type ReactNode, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { EnhancedNotes } from "../types";
import { colors, typography, spacing } from "../theme";

const TEMPLATES = [
  { id: "00000000-0000-0000-0000-000000000000", name: "Generic" },
  { id: "00000000-0000-0000-0000-000000000001", name: "1:1" },
  { id: "00000000-0000-0000-0000-000000000002", name: "Customer Discovery" },
  { id: "00000000-0000-0000-0000-000000000003", name: "Hiring" },
  { id: "00000000-0000-0000-0000-000000000004", name: "Stand-Up" },
  { id: "00000000-0000-0000-0000-000000000005", name: "Weekly Meeting" },
];

interface Props {
  sessionId?: string;
  initialNotes?: EnhancedNotes | null;
  onNotesChange?: (notes: EnhancedNotes | null) => void;
}

type MarkdownBlock =
  | { type: "heading"; level: number; text: string }
  | { type: "paragraph"; text: string }
  | { type: "unordered-list"; items: string[] }
  | { type: "ordered-list"; items: string[] }
  | { type: "blockquote"; lines: string[] }
  | { type: "code"; code: string };

export function NotesView({ sessionId, initialNotes, onNotesChange }: Props) {
  const [selectedTemplate, setSelectedTemplate] = useState(TEMPLATES[0].id);
  const [markdown, setMarkdown] = useState("");
  const [isGenerating, setIsGenerating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showThoughts, setShowThoughts] = useState(false);

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
      setSelectedTemplate(TEMPLATES[0].id);
      setError(null);
      setShowThoughts(false);
      return;
    }

    if (initialNotes) {
      setMarkdown(initialNotes.markdown);
      setSelectedTemplate(initialNotes.template.id);
    } else {
      setMarkdown("");
      setSelectedTemplate(TEMPLATES[0].id);
    }

    setError(null);
    setShowThoughts(false);
  }, [sessionId, initialNotes]);

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
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setIsGenerating(false);
    }
  };

  const parsed = parseGeneratedNotes(markdown);
  const displayedMarkdown = isGenerating ? markdown : parsed.visible;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", padding: spacing[4] }}>
      <div style={{ display: "flex", gap: spacing[2], marginBottom: spacing[3] }}>
        <select
          value={selectedTemplate}
          onChange={(e) => setSelectedTemplate(e.target.value)}
          style={{
            flex: 1,
            padding: `${spacing[2]}px`,
            background: colors.surface,
            color: colors.text,
            border: `1px solid ${colors.border}`,
            borderRadius: 4,
            fontSize: typography.md,
          }}
        >
          {TEMPLATES.map((t) => (
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

      {error && (
        <div style={{ color: colors.error, fontSize: typography.md, marginBottom: spacing[2] }}>{error}</div>
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

      {displayedMarkdown ? (
        <div style={{ flex: 1, overflowY: "auto" }}>
          <MarkdownPreview markdown={displayedMarkdown} />
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
          }}
        >
          {sessionId ? "Select a template and click Generate Notes" : "Start a session to generate notes"}
        </div>
      )}
    </div>
  );
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

function MarkdownPreview({ markdown }: { markdown: string }) {
  const blocks = parseMarkdownBlocks(markdown);

  return <div style={{ color: colors.text, fontSize: typography.md, lineHeight: 1.65 }}>{blocks.map(renderBlock)}</div>;
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

function renderBlock(block: MarkdownBlock, index: number) {
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
            color: colors.text,
            marginTop: index === 0 ? 0 : spacing[4],
            marginBottom: spacing[2],
            letterSpacing: block.level <= 2 ? "-0.02em" : "normal",
          }}
        >
          {renderInlineMarkdown(block.text)}
        </div>
      );
    }
    case "paragraph":
      return (
        <p key={`paragraph-${index}`} style={{ margin: `0 0 ${spacing[3]}px`, color: colors.textSecondary }}>
          {renderInlineMarkdown(block.text)}
        </p>
      );
    case "unordered-list":
      return renderList(block.items, index, false);
    case "ordered-list":
      return renderList(block.items, index, true);
    case "blockquote":
      return (
        <blockquote
          key={`blockquote-${index}`}
          style={{
            margin: `0 0 ${spacing[3]}px`,
            padding: `${spacing[2]}px ${spacing[3]}px`,
            borderLeft: `3px solid ${colors.accent}`,
            background: colors.accentMuted,
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
            background: colors.surfaceElevated,
            border: `1px solid ${colors.border}`,
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

function renderList(items: string[], index: number, ordered: boolean) {
  const listStyle: CSSProperties = {
    margin: `0 0 ${spacing[3]}px`,
    paddingLeft: spacing[4] + spacing[2],
    color: colors.textSecondary,
  };

  const ListTag = ordered ? "ol" : "ul";
  return (
    <ListTag key={`${ordered ? "ordered" : "unordered"}-${index}`} style={listStyle}>
      {items.map((item, itemIndex) => (
        <li key={itemIndex} style={{ marginBottom: spacing[1] }}>
          {renderInlineMarkdown(item)}
        </li>
      ))}
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
