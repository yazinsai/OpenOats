import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { AppSettings, MeetingTemplate } from "../types";
import { colors, typography, spacing, radius, styles } from "../theme";

interface EditState {
  id: string | null; // null = new template
  name: string;
  system_prompt: string;
}

type Section = "notes" | "suggestions";

export function PromptsView() {
  const [section, setSection] = useState<Section>("notes");

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      {/* Sub-tabs */}
      <div style={{ display: "flex", borderBottom: `1px solid ${colors.border}`, paddingLeft: spacing[4] }}>
        {(["notes", "suggestions"] as Section[]).map((s) => (
          <button
            key={s}
            onClick={() => setSection(s)}
            style={{
              background: "transparent",
              border: "none",
              borderBottom: section === s ? `2px solid ${colors.accent}` : "2px solid transparent",
              color: section === s ? colors.accent : colors.textSecondary,
              fontSize: typography.md,
              fontWeight: section === s ? 600 : 400,
              padding: `${spacing[2]}px ${spacing[3]}px`,
              cursor: "pointer",
              textTransform: "capitalize",
            }}
          >
            {s === "notes" ? "Note Prompts" : "Suggestion Prompts"}
          </button>
        ))}
      </div>

      <div style={{ flex: 1, overflowY: "auto" }}>
        {section === "notes" ? <NotePromptsSection /> : <SuggestionPromptsSection />}
      </div>
    </div>
  );
}

// ── Note Prompts ──────────────────────────────────────────────────────────────

function NotePromptsSection() {
  const [templates, setTemplates] = useState<MeetingTemplate[]>([]);
  const [editState, setEditState] = useState<EditState | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = () => {
    invoke<MeetingTemplate[]>("list_templates").then(setTemplates);
  };

  useEffect(() => {
    load();
  }, []);

  const startNew = () => {
    setEditState({ id: null, name: "", system_prompt: "" });
    setError(null);
  };

  const startEdit = (t: MeetingTemplate) => {
    setEditState({ id: t.id, name: t.name, system_prompt: t.system_prompt });
    setError(null);
  };

  const cancel = () => {
    setEditState(null);
    setError(null);
  };

  const save = async () => {
    if (!editState) return;
    if (!editState.name.trim()) {
      setError("Name is required.");
      return;
    }
    if (!editState.system_prompt.trim()) {
      setError("Prompt is required.");
      return;
    }

    setSaving(true);
    setError(null);
    try {
      const template: MeetingTemplate = {
        id: editState.id ?? crypto.randomUUID(),
        name: editState.name.trim(),
        icon: "doc.text",
        system_prompt: editState.system_prompt.trim(),
        is_built_in: false,
      };
      await invoke("save_template", { template });
      load();
      setEditState(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const deleteTemplate = async (id: string) => {
    try {
      await invoke("delete_template", { id });
      load();
    } catch (e) {
      setError(String(e));
    }
  };

  if (editState !== null) {
    return (
      <div style={{ padding: spacing[4], display: "flex", flexDirection: "column", gap: spacing[3] }}>
        <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
          <button onClick={cancel} style={{ ...styles.buttonSecondary, padding: `${spacing[1]}px ${spacing[2]}px` }}>
            ← Back
          </button>
          <h2 style={{ margin: 0, fontSize: typography["2xl"], fontWeight: 700, color: colors.text }}>
            {editState.id === null ? "New Note Prompt" : "Edit Note Prompt"}
          </h2>
        </div>

        {error && <div style={{ color: colors.error, fontSize: typography.md }}>{error}</div>}

        <div style={{ display: "flex", flexDirection: "column", gap: spacing[1] }}>
          <label style={{ fontSize: typography.sm, color: colors.textSecondary, fontWeight: 500 }}>Name</label>
          <input
            value={editState.name}
            onChange={(e) => setEditState((s) => s && { ...s, name: e.target.value })}
            placeholder="e.g. Sales Call"
            style={styles.input}
          />
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: spacing[1] }}>
          <label style={{ fontSize: typography.sm, color: colors.textSecondary, fontWeight: 500 }}>System Prompt</label>
          <textarea
            value={editState.system_prompt}
            onChange={(e) => setEditState((s) => s && { ...s, system_prompt: e.target.value })}
            placeholder="You are a meeting notes assistant. Given a transcript..."
            style={{ ...styles.input, minHeight: 260, resize: "vertical", lineHeight: 1.5, fontFamily: "monospace" }}
          />
        </div>

        <div style={{ display: "flex", gap: spacing[2] }}>
          <button
            onClick={save}
            disabled={saving}
            style={{ ...styles.button, opacity: saving ? 0.6 : 1, cursor: saving ? "not-allowed" : "pointer" }}
          >
            {saving ? "Saving..." : "Save Prompt"}
          </button>
          <button onClick={cancel} style={styles.buttonSecondary}>
            Cancel
          </button>
        </div>
      </div>
    );
  }

  const builtIns = templates.filter((t) => t.is_built_in);
  const custom = templates.filter((t) => !t.is_built_in);

  return (
    <div style={{ padding: spacing[4], display: "flex", flexDirection: "column", gap: spacing[4] }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <h2 style={{ margin: 0, fontSize: typography["2xl"], fontWeight: 700, color: colors.text }}>Note Prompts</h2>
          <p style={{ margin: `${spacing[1]}px 0 0`, fontSize: typography.sm, color: colors.textMuted }}>
            Customize how notes are generated for different meeting types.
          </p>
        </div>
        <button onClick={startNew} style={styles.button}>
          + New Prompt
        </button>
      </div>

      {error && <div style={{ color: colors.error, fontSize: typography.md }}>{error}</div>}

      {custom.length > 0 && (
        <section>
          <SectionLabel>Custom</SectionLabel>
          <div style={{ display: "flex", flexDirection: "column", gap: spacing[2] }}>
            {custom.map((t) => (
              <TemplateCard key={t.id} template={t} onEdit={() => startEdit(t)} onDelete={() => deleteTemplate(t.id)} />
            ))}
          </div>
        </section>
      )}

      <section>
        <SectionLabel>Built-in</SectionLabel>
        <div style={{ display: "flex", flexDirection: "column", gap: spacing[2] }}>
          {builtIns.map((t) => (
            <TemplateCard key={t.id} template={t} />
          ))}
        </div>
      </section>
    </div>
  );
}

// ── Suggestion Prompts ────────────────────────────────────────────────────────

const SUGGESTION_PROMPT_FIELDS: { key: keyof Pick<AppSettings, "kbSurfacingSystemPrompt" | "suggestionSynthesisSystemPrompt" | "smartQuestionSystemPrompt">; label: string; description: string }[] = [
  {
    key: "kbSurfacingSystemPrompt",
    label: "KB Surfacing Gate",
    description: "Instructs the LLM when to surface a knowledge base suggestion. Must return valid JSON.",
  },
  {
    key: "suggestionSynthesisSystemPrompt",
    label: "Suggestion Synthesis",
    description: "Instructs the LLM how to write the actual suggestion text shown to the user.",
  },
  {
    key: "smartQuestionSystemPrompt",
    label: "Smart Question Gate",
    description: "Instructs the LLM when to surface a clarifying question. Must return valid JSON.",
  },
];

function SuggestionPromptsSection() {
  const [prompts, setPrompts] = useState<Pick<AppSettings, "kbSurfacingSystemPrompt" | "suggestionSynthesisSystemPrompt" | "smartQuestionSystemPrompt"> | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    invoke<AppSettings>("get_settings").then((s) =>
      setPrompts({
        kbSurfacingSystemPrompt: s.kbSurfacingSystemPrompt,
        suggestionSynthesisSystemPrompt: s.suggestionSynthesisSystemPrompt,
        smartQuestionSystemPrompt: s.smartQuestionSystemPrompt,
      })
    );
  }, []);

  const save = async () => {
    if (!prompts) return;
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      const current = await invoke<AppSettings>("get_settings");
      await invoke("save_settings", {
        settings: { ...current, ...prompts },
      });
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  if (!prompts) {
    return (
      <div style={{ padding: spacing[4], color: colors.textMuted, fontSize: typography.md }}>Loading...</div>
    );
  }

  return (
    <div style={{ padding: spacing[4], display: "flex", flexDirection: "column", gap: spacing[4] }}>
      <div>
        <h2 style={{ margin: 0, fontSize: typography["2xl"], fontWeight: 700, color: colors.text }}>Suggestion Prompts</h2>
        <p style={{ margin: `${spacing[1]}px 0 0`, fontSize: typography.sm, color: colors.textMuted }}>
          Configure the system instructions sent to the LLM during live suggestion generation.
        </p>
      </div>

      {error && <div style={{ color: colors.error, fontSize: typography.md }}>{error}</div>}

      {SUGGESTION_PROMPT_FIELDS.map(({ key, label, description }) => (
        <div key={key} style={{ display: "flex", flexDirection: "column", gap: spacing[1] }}>
          <label style={{ fontSize: typography.md, fontWeight: 600, color: colors.text }}>{label}</label>
          <p style={{ margin: 0, fontSize: typography.sm, color: colors.textMuted }}>{description}</p>
          <textarea
            value={prompts[key]}
            onChange={(e) => setPrompts((p) => p && { ...p, [key]: e.target.value })}
            style={{ ...styles.input, minHeight: 80, resize: "vertical", lineHeight: 1.5, fontFamily: "monospace" }}
          />
        </div>
      ))}

      <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
        <button
          onClick={save}
          disabled={saving}
          style={{ ...styles.button, opacity: saving ? 0.6 : 1, cursor: saving ? "not-allowed" : "pointer" }}
        >
          {saving ? "Saving..." : "Save"}
        </button>
        {saved && <span style={{ fontSize: typography.sm, color: colors.success }}>Saved</span>}
      </div>
    </div>
  );
}

// ── Shared helpers ────────────────────────────────────────────────────────────

function SectionLabel({ children }: { children: string }) {
  return (
    <div
      style={{
        fontSize: typography.sm,
        fontWeight: 600,
        color: colors.textMuted,
        textTransform: "uppercase",
        letterSpacing: "0.08em",
        marginBottom: spacing[2],
      }}
    >
      {children}
    </div>
  );
}

function TemplateCard({
  template,
  onEdit,
  onDelete,
}: {
  template: MeetingTemplate;
  onEdit?: () => void;
  onDelete?: () => void;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div
      style={{
        background: colors.surface,
        border: `1px solid ${colors.border}`,
        borderRadius: radius.lg,
        overflow: "hidden",
      }}
    >
      <div
        style={{ display: "flex", alignItems: "center", gap: spacing[2], padding: `${spacing[2]}px ${spacing[3]}px`, cursor: "pointer" }}
        onClick={() => setExpanded((v) => !v)}
      >
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
            <span style={{ fontSize: typography.md, fontWeight: 600, color: colors.text }}>{template.name}</span>
            {template.is_built_in && (
              <span
                style={{
                  fontSize: typography.xs,
                  color: colors.textMuted,
                  background: colors.surfaceElevated,
                  border: `1px solid ${colors.border}`,
                  borderRadius: radius.sm,
                  padding: "1px 6px",
                }}
              >
                built-in
              </span>
            )}
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: spacing[1] }}>
          {onEdit && (
            <button
              onClick={(e) => { e.stopPropagation(); onEdit(); }}
              style={{ ...styles.buttonSecondary, padding: `${spacing[1]}px ${spacing[2]}px`, fontSize: typography.sm }}
            >
              Edit
            </button>
          )}
          {onDelete && (
            <button
              onClick={(e) => { e.stopPropagation(); onDelete(); }}
              style={{ ...styles.buttonDanger, padding: `${spacing[1]}px ${spacing[2]}px`, fontSize: typography.sm }}
            >
              Delete
            </button>
          )}
          <span style={{ color: colors.textMuted, fontSize: typography.sm }}>{expanded ? "▲" : "▼"}</span>
        </div>
      </div>
      {expanded && (
        <div
          style={{
            padding: `${spacing[2]}px ${spacing[3]}px ${spacing[3]}px`,
            borderTop: `1px solid ${colors.border}`,
            background: colors.surfaceElevated,
          }}
        >
          <pre
            style={{
              margin: 0,
              whiteSpace: "pre-wrap",
              fontSize: typography.sm,
              color: colors.textSecondary,
              lineHeight: 1.6,
              fontFamily: "monospace",
            }}
          >
            {template.system_prompt}
          </pre>
        </div>
      )}
    </div>
  );
}
