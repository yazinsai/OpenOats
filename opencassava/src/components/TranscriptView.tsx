import { useEffect, useRef } from "react";
import type { Utterance } from "../types";
import { colors, typography, spacing } from "../theme";

interface Props {
  utterances: Utterance[];
  volatileYouText?: string;
  volatileThemText?: string;
  searchQuery?: string;
  searchResults?: number[];
  currentSearchIndex?: number;
}

// Format timestamp to relative time or clock time
function formatTimestamp(timestamp: string): string {
  const date = new Date(timestamp);
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// Group utterances by time buckets for long sessions
function groupByTimeBucket(utterances: Utterance[]): { time: string; items: Utterance[] }[] {
  const buckets: { time: string; items: Utterance[] }[] = [];
  let currentBucket: { time: string; items: Utterance[] } | null = null;

  for (const utterance of utterances) {
    const time = formatTimestamp(utterance.timestamp);
    const hour = time.split(":")[0];

    if (!currentBucket || currentBucket.time.split(":")[0] !== hour) {
      currentBucket = { time, items: [] };
      buckets.push(currentBucket);
    }
    currentBucket.items.push(utterance);
  }

  return buckets;
}

// Highlight search matches in text
function HighlightText({ text, query, isCurrent }: { text: string; query?: string; isCurrent?: boolean }) {
  if (!query || !query.trim()) {
    return <>{text}</>;
  }

  const parts = text.split(new RegExp(`(${escapeRegExp(query)})`, "gi"));

  return (
    <>
      {parts.map((part, i) => {
        const isMatch = part.toLowerCase() === query.toLowerCase();
        if (!isMatch) return part;
        return (
          <mark
            key={i}
            style={{
              background: isCurrent ? `${colors.accent}40` : "#fef3c7",
              color: colors.text,
              padding: "0 2px",
              borderRadius: 2,
              fontWeight: isCurrent ? 600 : 400,
            }}
          >
            {part}
          </mark>
        );
      })}
    </>
  );
}

function escapeRegExp(string: string): string {
  return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Utterance bubble component
function UtteranceBubble({
  utterance,
  isHighlighted,
  searchQuery,
}: {
  utterance: Utterance;
  isHighlighted?: boolean;
  searchQuery?: string;
}) {
  const isYou = utterance.speaker === "you";

  return (
    <div
      style={{
        display: "flex",
        gap: spacing[2],
        marginBottom: spacing[3],
        alignItems: "flex-start",
        padding: isHighlighted ? `${spacing[2]}px` : 0,
        background: isHighlighted ? `${colors.accent}10` : "transparent",
        borderRadius: isHighlighted ? 6 : 0,
        border: isHighlighted ? `1px solid ${colors.accent}30` : "none",
      }}
    >
      {/* Speaker label */}
      <div
        style={{
          minWidth: 40,
          textAlign: "right",
          fontSize: typography.sm,
          fontWeight: 600,
          color: isYou ? colors.you : colors.them,
          textTransform: "uppercase",
          letterSpacing: "0.5px",
          paddingTop: 2,
        }}
      >
        {isYou ? "You" : "Them"}
      </div>

      {/* Content */}
      <div style={{ flex: 1 }}>
        <span style={{ fontSize: typography.md, color: colors.text, lineHeight: 1.5 }}>
          <HighlightText text={utterance.text} query={searchQuery} />
        </span>
        <span style={{ fontSize: typography.xs, color: colors.textMuted, marginLeft: spacing[2] }}>
          {formatTimestamp(utterance.timestamp)}
        </span>
      </div>
    </div>
  );
}

// Volatile text indicator (live transcription)
function VolatileIndicator({ text, speaker }: { text: string; speaker: "you" | "them" }) {
  const isYou = speaker === "you";

  return (
    <div
      style={{
        display: "flex",
        gap: spacing[2],
        marginBottom: spacing[3],
        alignItems: "flex-start",
        opacity: 0.6,
      }}
    >
      <div
        style={{
          minWidth: 40,
          textAlign: "right",
          fontSize: typography.sm,
          fontWeight: 600,
          color: isYou ? colors.you : colors.them,
          textTransform: "uppercase",
          letterSpacing: "0.5px",
          paddingTop: 2,
        }}
      >
        {isYou ? "You" : "Them"}
      </div>
      <div style={{ flex: 1, display: "flex", alignItems: "center", gap: spacing[2] }}>
        <span style={{ fontSize: typography.md, color: colors.textSecondary, lineHeight: 1.5 }}>
          {text}
        </span>
        {/* Pulsing indicator */}
        <span
          style={{
            width: 4,
            height: 4,
            borderRadius: "50%",
            background: isYou ? colors.you : colors.them,
            animation: "pulse 1s ease-in-out infinite",
          }}
        />
      </div>
    </div>
  );
}

export function TranscriptView({
  utterances,
  volatileYouText,
  volatileThemText,
  searchQuery,
  searchResults = [],
  currentSearchIndex = 0,
}: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const highlightedRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom only when not searching
  useEffect(() => {
    if (!searchQuery) {
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [utterances.length, searchQuery]);

  // Scroll to current search result
  useEffect(() => {
    if (searchResults.length > 0 && highlightedRef.current) {
      highlightedRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [currentSearchIndex, searchResults]);

  // Empty state
  if (utterances.length === 0 && !volatileYouText && !volatileThemText) {
    return (
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          color: colors.textMuted,
          padding: spacing[4],
          textAlign: "center",
        }}
      >
        <div
          style={{
            width: 64,
            height: 64,
            borderRadius: 16,
            background: `${colors.accent}15`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 32,
            marginBottom: spacing[3],
          }}
        >
          🎙️
        </div>
        <h4
          style={{
            fontSize: typography.lg,
            fontWeight: 600,
            color: colors.text,
            margin: `0 0 ${spacing[2]}px`,
          }}
        >
          Ready to capture
        </h4>
        <p style={{ fontSize: typography.md, color: colors.textSecondary, margin: 0, maxWidth: 280, lineHeight: 1.5 }}>
          Press <kbd style={{ padding: "2px 6px", background: colors.surfaceElevated, borderRadius: 4, fontFamily: "monospace" }}>Cmd+Shift+S</kbd> or click Record to start.
        </p>
      </div>
    );
  }

  const grouped = groupByTimeBucket(utterances);
  let utteranceCounter = 0;

  return (
    <div
      ref={scrollRef}
      style={{
        flex: 1,
        overflowY: "auto",
        padding: spacing[4],
        background: colors.background,
      }}
    >
      {grouped.map((bucket, bucketIndex) => (
        <div key={bucket.time}>
          {bucketIndex > 0 && (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: spacing[2],
                margin: `${spacing[4]}px 0`,
              }}
            >
              <div style={{ flex: 1, height: 1, background: colors.border }} />
              <span
                style={{
                  fontSize: typography.xs,
                  color: colors.textMuted,
                  textTransform: "uppercase",
                  letterSpacing: "1px",
                }}
              >
                {bucket.time}
              </span>
              <div style={{ flex: 1, height: 1, background: colors.border }} />
            </div>
          )}

          {bucket.items.map((utterance) => {
            const isHighlighted = searchResults[currentSearchIndex] === utteranceCounter;
            const ref = isHighlighted ? highlightedRef : undefined;
            utteranceCounter++;

            return (
              <div key={utterance.id} ref={ref}>
                <UtteranceBubble
                  utterance={utterance}
                  isHighlighted={isHighlighted}
                  searchQuery={searchQuery}
                />
              </div>
            );
          })}
        </div>
      ))}

      {volatileYouText && <VolatileIndicator text={volatileYouText} speaker="you" />}
      {volatileThemText && <VolatileIndicator text={volatileThemText} speaker="them" />}

      <div ref={bottomRef} />

      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; transform: scale(1); }
          50% { opacity: 0.5; transform: scale(0.8); }
        }
      `}</style>
    </div>
  );
}
