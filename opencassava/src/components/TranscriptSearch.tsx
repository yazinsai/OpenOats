import { useState, useRef, useEffect } from "react";
import { colors, typography, spacing } from "../theme";

interface Props {
  onSearch: (query: string) => void;
  onClose: () => void;
  resultCount?: number;
  currentIndex?: number;
  onNext?: () => void;
  onPrev?: () => void;
}

export function TranscriptSearch({
  onSearch,
  onClose,
  resultCount = 0,
  currentIndex = 0,
  onNext,
  onPrev,
}: Props) {
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setQuery(e.target.value);
    onSearch(e.target.value);
  };

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: spacing[2],
        padding: `${spacing[2]}px ${spacing[3]}px`,
        background: colors.surface,
        borderBottom: `1px solid ${colors.border}`,
      }}
    >
      <span style={{ fontSize: typography.md, color: colors.textMuted }}>🔍</span>
      <input
        ref={inputRef}
        type="text"
        placeholder="Search transcript..."
        value={query}
        onChange={handleChange}
        style={{
          flex: 1,
          padding: `${spacing[1]}px`,
          background: "transparent",
          border: "none",
          fontSize: typography.md,
          color: colors.text,
          outline: "none",
        }}
      />

      {query && (
        <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
          {resultCount > 0 && (
            <span style={{ fontSize: typography.sm, color: colors.textSecondary }}>
              {currentIndex + 1} / {resultCount}
            </span>
          )}
          {resultCount > 1 && (
            <div style={{ display: "flex", gap: 2 }}>
              <button
                onClick={onPrev}
                disabled={currentIndex === 0}
                style={{
                  padding: "2px 6px",
                  background: colors.background,
                  border: `1px solid ${colors.border}`,
                  borderRadius: 4,
                  fontSize: typography.sm,
                  color: currentIndex === 0 ? colors.textMuted : colors.text,
                  cursor: currentIndex === 0 ? "not-allowed" : "pointer",
                }}
              >
                ↑
              </button>
              <button
                onClick={onNext}
                disabled={currentIndex >= resultCount - 1}
                style={{
                  padding: "2px 6px",
                  background: colors.background,
                  border: `1px solid ${colors.border}`,
                  borderRadius: 4,
                  fontSize: typography.sm,
                  color: currentIndex >= resultCount - 1 ? colors.textMuted : colors.text,
                  cursor: currentIndex >= resultCount - 1 ? "not-allowed" : "pointer",
                }}
              >
                ↓
              </button>
            </div>
          )}
          {resultCount === 0 && query && (
            <span style={{ fontSize: typography.sm, color: colors.textMuted }}>No results</span>
          )}
        </div>
      )}

      <button
        onClick={onClose}
        style={{
          background: "transparent",
          border: "none",
          color: colors.textMuted,
          cursor: "pointer",
          fontSize: 18,
          padding: 4,
          lineHeight: 1,
        }}
      >
        ×
      </button>
    </div>
  );
}
