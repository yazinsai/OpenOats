import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { Utterance } from "../types";
import { colors, typography, spacing } from "../theme";

interface Props {
  utterances: Utterance[];
  onClose: () => void;
}

type ExportFormat = "markdown" | "txt" | "json";

export function ExportMenu({ utterances, onClose }: Props) {
  const [format, setFormat] = useState<ExportFormat>("markdown");
  const [isExporting, setIsExporting] = useState(false);
  const [copied, setCopied] = useState(false);

  const formatUtterances = (utterances: Utterance[], format: ExportFormat): string => {
    switch (format) {
      case "markdown":
        return utterances
          .map(
            (u) =>
              `**${u.speaker === "you" ? "You" : "Them"}** (${new Date(
                u.timestamp
              ).toLocaleTimeString()})\n${u.text}\n`
          )
          .join("\n");
      case "txt":
        return utterances
          .map(
            (u) =>
              `[${u.speaker === "you" ? "You" : "Them"}] ${new Date(
                u.timestamp
              ).toLocaleTimeString()}: ${u.text}`
          )
          .join("\n");
      case "json":
        return JSON.stringify(utterances, null, 2);
    }
  };

  const handleCopy = async () => {
    const content = formatUtterances(utterances, format);
    try {
      await navigator.clipboard.writeText(content);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error("Failed to copy:", err);
    }
  };

  const handleSave = async () => {
    setIsExporting(true);
    try {
      const content = formatUtterances(utterances, format);
      const extension = format === "markdown" ? "md" : format;
      const defaultName = `transcript-${new Date().toISOString().split("T")[0]}.${extension}`;

      await invoke("save_transcript", { content, defaultName });
    } catch (err) {
      console.error("Failed to save:", err);
    } finally {
      setIsExporting(false);
      onClose();
    }
  };

  return (
    <>
      {/* Backdrop */}
      <div
        onClick={onClose}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(0,0,0,0.2)",
          zIndex: 100,
        }}
      />

      {/* Menu */}
      <div
        style={{
          position: "fixed",
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          background: colors.surface,
          border: `1px solid ${colors.border}`,
          borderRadius: 12,
          padding: spacing[4],
          width: 360,
          zIndex: 101,
          boxShadow: "0 20px 60px rgba(0,0,0,0.15)",
        }}
      >
        <h3
          style={{
            margin: `0 0 ${spacing[3]}px`,
            fontSize: typography.lg,
            fontWeight: 600,
            color: colors.text,
          }}
        >
          Export Transcript
        </h3>

        <div style={{ marginBottom: spacing[3] }}>
          <label
            style={{
              display: "block",
              fontSize: typography.sm,
              color: colors.textSecondary,
              marginBottom: spacing[2],
            }}
          >
            Format
          </label>
          <div style={{ display: "flex", gap: spacing[2] }}>
            {(["markdown", "txt", "json"] as ExportFormat[]).map((f) => (
              <button
                key={f}
                onClick={() => setFormat(f)}
                style={{
                  flex: 1,
                  padding: `${spacing[2]}px`,
                  background: format === f ? `${colors.accent}15` : colors.background,
                  color: format === f ? colors.accent : colors.text,
                  border: `1px solid ${format === f ? colors.accent : colors.border}`,
                  borderRadius: 6,
                  fontSize: typography.md,
                  cursor: "pointer",
                  fontWeight: format === f ? 600 : 400,
                  textTransform: "capitalize",
                }}
              >
                {f === "markdown" ? "Markdown" : f}
              </button>
            ))}
          </div>
        </div>

        <div
          style={{
            background: colors.background,
            border: `1px solid ${colors.border}`,
            borderRadius: 6,
            padding: spacing[3],
            marginBottom: spacing[3],
            maxHeight: 120,
            overflow: "auto",
          }}
        >
          <pre
            style={{
              margin: 0,
              fontSize: typography.sm,
              color: colors.textSecondary,
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
            }}
          >
            {formatUtterances(utterances.slice(0, 3), format)}
            {utterances.length > 3 && "\n..."}
          </pre>
        </div>

        <div style={{ display: "flex", gap: spacing[2] }}>
          <button
            onClick={handleCopy}
            style={{
              flex: 1,
              padding: `${spacing[2]}px`,
              background: colors.background,
              color: colors.text,
              border: `1px solid ${colors.border}`,
              borderRadius: 6,
              fontSize: typography.md,
              cursor: "pointer",
              fontWeight: 500,
            }}
          >
            {copied ? "✓ Copied!" : "Copy to Clipboard"}
          </button>
          <button
            onClick={handleSave}
            disabled={isExporting}
            style={{
              flex: 1,
              padding: `${spacing[2]}px`,
              background: colors.accent,
              color: colors.textInverse,
              border: "none",
              borderRadius: 6,
              fontSize: typography.md,
              cursor: isExporting ? "not-allowed" : "pointer",
              fontWeight: 600,
              opacity: isExporting ? 0.7 : 1,
            }}
          >
            {isExporting ? "Saving..." : "Save File"}
          </button>
        </div>

        <button
          onClick={onClose}
          style={{
            width: "100%",
            marginTop: spacing[2],
            padding: `${spacing[2]}px`,
            background: "transparent",
            color: colors.textMuted,
            border: "none",
            fontSize: typography.sm,
            cursor: "pointer",
          }}
        >
          Cancel
        </button>
      </div>
    </>
  );
}
