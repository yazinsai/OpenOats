import { useState } from "react"; // used by BulletRow
import { invoke } from "@tauri-apps/api/core";
import { emitTo } from "@tauri-apps/api/event";
import type { Suggestion } from "../types";

const colors = {
  background: "#111111",
  surface: "#1a1a1a",
  border: "#333333",
  text: "#eeeeee",
  textSecondary: "#888888",
  textMuted: "#666666",
  accent: "#2b7a78",
  accentLight: "#3a9a98",
  success: "#27ae60",
  them: "#d2994d",
};

const typography = {
  xs: 10,
  sm: 11,
  base: 12,
  md: 13,
  lg: 14,
};

const spacing = {
  1: 4,
  2: 8,
  3: 12,
  4: 16,
  6: 24,
};

interface Props {
  suggestions: Suggestion[];
  isGenerating?: boolean;
  kbConnected?: boolean;
  kbFileCount?: number;
  lastCheckedAt?: string | null;
  lastCheckSurfaced?: boolean | null;
  onDismiss?: (id: string) => void;
  onInjectTest?: (suggestion: { id: string; kind: string; text: string; kbHits: any[] }) => void;
}

interface ParsedBullet {
  id: string;
  headline: string;
  detail?: string;
}

function formatRelativeTime(iso: string | null | undefined): string {
  if (!iso) return "Waiting for first analysis";
  const deltaSeconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (deltaSeconds < 5) return "Just now";
  if (deltaSeconds < 60) return `${deltaSeconds}s ago`;
  const minutes = Math.floor(deltaSeconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}

function parseBullets(text: string): ParsedBullet[] {
  const lines = text.split("\n");
  const bullets: ParsedBullet[] = [];
  let currentHeadline: string | null = null;
  let currentDetail: string | null = null;

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.startsWith("\u2022") || trimmed.startsWith("-") || trimmed.startsWith("*")) {
      if (currentHeadline) {
        bullets.push({
          id: Math.random().toString(36).slice(2, 11),
          headline: currentHeadline,
          detail: currentDetail || undefined,
        });
      }
      currentHeadline = trimmed.slice(1).trim();
      currentDetail = null;
    } else if (trimmed.startsWith(">")) {
      const detail = trimmed.slice(1).trim();
      if (detail) {
        currentDetail = currentDetail ? `${currentDetail} ${detail}` : detail;
      }
    } else if (trimmed && trimmed !== "\u2014" && currentHeadline) {
      currentDetail = currentDetail ? `${currentDetail} ${trimmed}` : trimmed;
    }
  }

  if (currentHeadline) {
    bullets.push({
      id: Math.random().toString(36).slice(2, 11),
      headline: currentHeadline,
      detail: currentDetail || undefined,
    });
  }

  return bullets;
}

function EmptyState({
  kbConnected,
  kbFileCount,
  lastCheckedAt,
  lastCheckSurfaced,
}: {
  kbConnected: boolean;
  kbFileCount: number;
  lastCheckedAt?: string | null;
  lastCheckSurfaced?: boolean | null;
}) {
  if (!kbConnected) {
    return (
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          padding: `${spacing[6]}px`,
          textAlign: "center",
        }}
      >
        <div
          style={{
            minWidth: 48,
            height: 48,
            borderRadius: 12,
            background: `${colors.accent}15`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: typography.base,
            fontWeight: 700,
            color: colors.accentLight,
            marginBottom: spacing[3],
            padding: "0 12px",
          }}
        >
          AI
        </div>
        <h4
          style={{
            fontSize: typography.lg,
            fontWeight: 600,
            color: colors.text,
            margin: `0 0 ${spacing[2]}px`,
          }}
        >
          Suggestions are context-aware
        </h4>
        <p
          style={{
            fontSize: typography.md,
            color: colors.textSecondary,
            margin: `0 0 ${spacing[4]}px`,
            maxWidth: 280,
            lineHeight: 1.5,
          }}
        >
          Connect a knowledge base for note-backed prompts. OpenOats can also surface smart questions when the conversation exposes missing information.
        </p>
        <div style={{ display: "flex", gap: spacing[2] }}>
          <button
            style={{
              padding: `${spacing[2]}px ${spacing[3]}px`,
              background: colors.accent,
              color: "#fff",
              border: "none",
              borderRadius: 6,
              fontSize: typography.base,
              cursor: "pointer",
              fontWeight: 500,
            }}
            onClick={() => {
              const event = new CustomEvent("open-settings", { detail: { tab: "general" } });
              window.dispatchEvent(event);
            }}
          >
            Choose KB Folder
          </button>
        </div>
      </div>
    );
  }

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: `${spacing[6]}px`,
        textAlign: "center",
      }}
    >
      <div
        style={{
          minWidth: 48,
          height: 48,
          borderRadius: 12,
          background: `${colors.success}15`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: typography.base,
          fontWeight: 700,
          color: colors.success,
          marginBottom: spacing[3],
          padding: "0 12px",
        }}
      >
        KB
      </div>
      <h4
        style={{
          fontSize: typography.lg,
          fontWeight: 600,
          color: colors.text,
          margin: `0 0 ${spacing[2]}px`,
        }}
      >
        Listening for relevant moments...
      </h4>
      <p
        style={{
          fontSize: typography.md,
          color: colors.textSecondary,
          margin: `0 0 ${spacing[2]}px`,
          maxWidth: 280,
          lineHeight: 1.5,
        }}
      >
        Suggestions appear when the other person mentions topics related to your knowledge base or leaves an important question unanswered.
      </p>
      <span
        style={{
          fontSize: typography.sm,
          color: colors.textMuted,
        }}
      >
        Last checked: {formatRelativeTime(lastCheckedAt)} · {lastCheckSurfaced ? "Suggestion found recently" : kbFileCount > 0 ? `${kbFileCount} docs indexed` : "KB connected"}
      </span>
    </div>
  );
}

function BulletRow({ bullet }: { bullet: ParsedBullet }) {
  const [isExpanded, setIsExpanded] = useState(false);
  const hasDetail = !!bullet.detail;

  return (
    <div style={{ marginBottom: spacing[2] }}>
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          gap: spacing[1],
          cursor: hasDetail ? "pointer" : "default",
        }}
        onClick={() => hasDetail && setIsExpanded(!isExpanded)}
      >
        {hasDetail && (
          <span
            style={{
              fontSize: typography.xs,
              color: colors.textMuted,
              marginTop: 2,
              width: 12,
              flexShrink: 0,
            }}
          >
            {isExpanded ? "▼" : "▶"}
          </span>
        )}
        <span
          style={{
            fontSize: typography.md,
            fontWeight: 500,
            color: colors.text,
            lineHeight: 1.4,
          }}
        >
          {bullet.headline}
        </span>
      </div>
      {isExpanded && bullet.detail && (
        <div
          style={{
            marginTop: spacing[1],
            marginLeft: hasDetail ? 16 : 0,
            fontSize: typography.sm,
            color: colors.textSecondary,
            lineHeight: 1.5,
          }}
        >
          {bullet.detail}
        </div>
      )}
    </div>
  );
}

function SuggestionCard({
  suggestion,
  isPrimary,
  onDismiss,
}: {
  suggestion: Suggestion;
  isPrimary: boolean;
  onDismiss: () => void;
}) {
  const bullets = parseBullets(suggestion.text);
  const hasSources = suggestion.kbHits && suggestion.kbHits.length > 0;
  const isSmartQuestion = suggestion.kind === "smart_question";

  return (
    <div
      style={{
        background: isSmartQuestion
          ? `${colors.them}10`
          : isPrimary
            ? `${colors.accent}10`
            : colors.surface,
        border: `1px solid ${
          isSmartQuestion
            ? `${colors.them}30`
            : isPrimary
              ? `${colors.accent}30`
              : colors.border
        }`,
        borderRadius: 8,
        padding: spacing[3],
        marginBottom: spacing[2],
        animation: "slideIn 0.3s ease-out",
      }}
    >
      <div
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: spacing[1],
          padding: `${spacing[1]}px ${spacing[2]}px`,
          borderRadius: 999,
          background: isSmartQuestion ? `${colors.them}20` : `${colors.accent}15`,
          color: isSmartQuestion ? colors.them : colors.accentLight,
          fontSize: typography.xs,
          fontWeight: 600,
          textTransform: "uppercase",
          letterSpacing: "0.8px",
          marginBottom: spacing[2],
        }}
      >
        {isSmartQuestion ? "Smart Question" : "Talking Point"}
      </div>

      {bullets.length > 0 ? (
        bullets.map((bullet) => <BulletRow key={bullet.id} bullet={bullet} />)
      ) : (
        <p
          style={{
            fontSize: typography.md,
            color: colors.text,
            margin: 0,
            lineHeight: 1.5,
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
          }}
        >
          {suggestion.text}
        </p>
      )}

      {hasSources && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: spacing[1],
            marginTop: spacing[2],
            paddingTop: spacing[2],
            borderTop: `1px solid ${colors.border}`,
            fontSize: typography.xs,
            color: colors.textMuted,
          }}
        >
          <span style={{ fontWeight: 600, color: colors.textSecondary }}>Docs</span>
          <span>
            {suggestion.kbHits.slice(0, 3).map((h) => h.sourceFile).join(" · ")}
            {suggestion.kbHits.length > 3 && ` +${suggestion.kbHits.length - 3} more`}
          </span>
        </div>
      )}

      <div style={{ display: "flex", gap: spacing[2], marginTop: spacing[3] }}>
        <button
          onClick={onDismiss}
          style={{
            padding: `${spacing[1]}px ${spacing[2]}px`,
            background: "transparent",
            color: colors.textMuted,
            border: `1px solid ${colors.border}`,
            borderRadius: 4,
            fontSize: typography.sm,
            cursor: "pointer",
          }}
        >
          Dismiss
        </button>
      </div>
    </div>
  );
}

export function SuggestionsView({
  suggestions,
  isGenerating = false,
  kbConnected = false,
  kbFileCount = 0,
  lastCheckedAt = null,
  lastCheckSurfaced = null,
  onDismiss,
  onInjectTest,
}: Props) {

  const handleInjectTest = async () => {
    const fake = {
      id: crypto.randomUUID(),
      kind: "smart_question",
      text: "• Have you considered what their timeline looks like?\n> Understanding urgency helps prioritize the conversation.",
      kbHits: [],
    };
    onInjectTest?.(fake);
    await invoke("show_overlay").catch(() => {});
    await emitTo("overlay", "overlay-test-suggestion", { id: fake.id, text: fake.text }).catch(() => {});
  };

  if (suggestions.length === 0 && !isGenerating) {
    return (
      <div
        style={{
          flex: 1,
          overflowY: "auto",
          background: colors.background,
        }}
      >
        <div style={{ padding: spacing[3] }}>
          <button
            onClick={handleInjectTest}
            style={{
              padding: `${spacing[1]}px ${spacing[2]}px`,
              background: "transparent",
              color: colors.textMuted,
              border: `1px dashed ${colors.border}`,
              borderRadius: 4,
              fontSize: typography.xs,
              cursor: "pointer",
            }}
          >
            ⚡ Test overlay
          </button>
        </div>
        <EmptyState
          kbConnected={kbConnected}
          kbFileCount={kbFileCount}
          lastCheckedAt={lastCheckedAt}
          lastCheckSurfaced={lastCheckSurfaced}
        />
      </div>
    );
  }

  return (
    <div
      style={{
        flex: 1,
        overflowY: "auto",
        padding: spacing[3],
        background: colors.background,
      }}
    >
      <button
        onClick={handleInjectTest}
        style={{
          marginBottom: spacing[3],
          padding: `${spacing[1]}px ${spacing[2]}px`,
          background: "transparent",
          color: colors.textMuted,
          border: `1px dashed ${colors.border}`,
          borderRadius: 4,
          fontSize: typography.xs,
          cursor: "pointer",
        }}
      >
        ⚡ Test overlay
      </button>

      {isGenerating && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: spacing[2],
            padding: spacing[3],
            background: `${colors.accent}10`,
            borderRadius: 8,
            marginBottom: spacing[3],
          }}
        >
          <div
            style={{
              width: 16,
              height: 16,
              border: `2px solid ${colors.border}`,
              borderTopColor: colors.accent,
              borderRadius: "50%",
              animation: "spin 1s linear infinite",
            }}
          />
          <span style={{ fontSize: typography.md, color: colors.textSecondary }}>
            Evaluating conversation...
          </span>
        </div>
      )}

      {!isGenerating && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: spacing[2],
            padding: `${spacing[2]}px ${spacing[3]}px`,
            background: colors.surface,
            border: `1px solid ${colors.border}`,
            borderRadius: 8,
            marginBottom: spacing[3],
            fontSize: typography.sm,
            color: colors.textSecondary,
          }}
        >
          <span style={{ color: lastCheckSurfaced ? colors.success : colors.textMuted }}>
            {lastCheckSurfaced ? "●" : "○"}
          </span>
          <span>
            Last analysis: {formatRelativeTime(lastCheckedAt)}
            {lastCheckSurfaced ? " · surfaced a suggestion" : " · no suggestion surfaced"}
          </span>
        </div>
      )}

      {suggestions.length > 0 && (
        <div style={{ marginBottom: spacing[2] }}>
          <div
            style={{
              fontSize: typography.xs,
              color: colors.textMuted,
              textTransform: "uppercase",
              letterSpacing: "1px",
              marginBottom: spacing[3],
              fontWeight: 600,
            }}
          >
            Suggestions · {suggestions.length}
          </div>
          {suggestions.map((suggestion, index) => (
            <SuggestionCard
              key={suggestion.id}
              suggestion={suggestion}
              isPrimary={index === 0}
              onDismiss={() => onDismiss?.(suggestion.id)}
            />
          ))}
        </div>
      )}

      <style>{`
        @keyframes slideIn {
          from {
            opacity: 0;
            transform: translateY(-10px);
          }
          to {
            opacity: 1;
            transform: translateY(0);
          }
        }
        @keyframes spin {
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}
