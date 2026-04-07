import type { AppSettings, SidecastPersona, DebugLogEntry } from "./types.ts";
import { saveSettings, addPersona, removePersona, resetPersonas, exportSettingsJSON } from "./settings.ts";

type OnChange = (settings: AppSettings) => void;

// --- Helpers ---
function el(tag: string, cls?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  return e;
}

function label(text: string): HTMLElement {
  const l = el("label", "cfg-label");
  l.textContent = text;
  return l;
}

function fieldInput(type: string, value: string, placeholder: string, onInput: (v: string) => void): HTMLInputElement {
  const inp = document.createElement("input");
  inp.type = type;
  inp.value = value;
  inp.placeholder = placeholder;
  inp.className = "cfg-input";
  inp.addEventListener("input", () => onInput(inp.value));
  return inp;
}

function fieldSelect(options: [string, string][], value: string, onSelect: (v: string) => void): HTMLSelectElement {
  const sel = document.createElement("select");
  sel.className = "cfg-input";
  options.forEach(([val, text]) => {
    const opt = document.createElement("option");
    opt.value = val;
    opt.textContent = text;
    opt.selected = val === value;
    sel.appendChild(opt);
  });
  sel.addEventListener("change", () => onSelect(sel.value));
  return sel;
}

function fieldSlider(labelText: string, min: number, max: number, step: number, value: number, onInput: (v: number) => void): HTMLElement {
  const wrap = el("div", "cfg-slider-wrap");
  const header = el("div", "cfg-slider-header");
  const lbl = el("span", "cfg-label");
  lbl.textContent = labelText;
  const val = el("span", "cfg-slider-val");
  val.textContent = String(value);
  header.appendChild(lbl);
  header.appendChild(val);
  wrap.appendChild(header);

  const inp = document.createElement("input");
  inp.type = "range";
  inp.className = "cfg-range";
  inp.min = String(min);
  inp.max = String(max);
  inp.step = String(step);
  inp.value = String(value);
  inp.addEventListener("input", () => {
    const v = parseFloat(inp.value);
    val.textContent = String(v);
    onInput(v);
  });
  wrap.appendChild(inp);
  return wrap;
}

function fieldToggle(checked: boolean, labelText: string, onChange: (v: boolean) => void): HTMLElement {
  const row = el("div", "cfg-toggle");
  const cb = document.createElement("input");
  cb.type = "checkbox";
  cb.checked = checked;
  cb.addEventListener("change", () => onChange(cb.checked));
  const span = el("span");
  span.textContent = labelText;
  row.appendChild(cb);
  row.appendChild(span);
  return row;
}

function divider(): HTMLElement {
  return el("hr", "cfg-divider");
}

function groupHeading(text: string): HTMLElement {
  const h = el("div", "cfg-group-heading");
  h.textContent = text;
  return h;
}

// --- Model Picker ---
interface ModelPreset {
  id: string;
  tier: string;
  name: string;
  desc: string;
  color: string;
  icon: string; // Iconify Solar icon SVG
}

const MODEL_PRESETS: ModelPreset[] = [
  {
    id: "google/gemini-3.1-flash-lite-preview",
    tier: "Quick",
    name: "Gemini Flash Lite",
    desc: "Fast & cheap — good for testing",
    color: "#fbbf24",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"><path fill="currentColor" d="M13.692 3.346a.75.75 0 0 0-1.384 0l-2.097 4.997L5.05 6.44a.75.75 0 0 0-.987.987l1.903 5.16-4.997 2.098a.75.75 0 0 0 0 1.384l4.997 2.097L5.063 23.327a.75.75 0 0 0 .987.987l5.16-1.903 2.098 4.997a.75.75 0 0 0 1.384 0l2.097-4.997 5.161 1.903a.75.75 0 0 0 .987-.987l-1.903-5.16 4.997-2.098a.75.75 0 0 0 0-1.384l-4.997-2.097 1.903-5.161a.75.75 0 0 0-.987-.987l-5.16 1.903z"/></svg>`,
  },
  {
    id: "x-ai/grok-4.1-fast",
    tier: "Sharp",
    name: "Grok 4.1 Fast",
    desc: "Balanced speed & intelligence",
    color: "#818cf8",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2C6.477 2 2 6.477 2 12s4.477 10 10 10 10-4.477 10-10S17.523 2 12 2m-1.834 4.856a.75.75 0 0 1 1.074.32l1.178 2.243 2.243 1.179a.75.75 0 0 1 0 1.342l-2.243 1.178-1.178 2.243a.75.75 0 0 1-1.342 0l-1.179-2.243-2.243-1.178a.75.75 0 0 1 0-1.342l2.243-1.179 1.179-2.243a.75.75 0 0 1 .268-.32M16.25 14a.75.75 0 0 1 .694.468l.395.974.974.395a.75.75 0 0 1 0 1.388l-.974.395-.395.974a.75.75 0 0 1-1.388 0l-.395-.974-.974-.395a.75.75 0 0 1 0-1.388l.974-.395.395-.974A.75.75 0 0 1 16.25 14"/></svg>`,
  },
  {
    id: "openai/gpt-5.4",
    tier: "Genius",
    name: "GPT-5.4",
    desc: "Maximum intelligence — best quality",
    color: "#4ade80",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2a4 4 0 0 0-4 4v1H7a3 3 0 0 0-3 3v8a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3v-8a3 3 0 0 0-3-3h-1V6a4 4 0 0 0-4-4m-2 4a2 2 0 1 1 4 0v1h-4zm-.5 7a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3m5 0a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3M9 16h6a.75.75 0 0 1 0 1.5H9A.75.75 0 0 1 9 16"/></svg>`,
  },
];

function findPreset(modelId: string): ModelPreset | undefined {
  return MODEL_PRESETS.find((p) => p.id === modelId);
}

function renderModelPicker(settings: AppSettings, onChange: OnChange): HTMLElement {
  const picker = el("div", "model-picker");
  const preset = findPreset(settings.model);

  // Selected display
  const selected = el("div", "model-selected");
  const updateSelected = (p: ModelPreset | undefined, modelId: string) => {
    selected.innerHTML = p
      ? `<div class="model-selected-icon" style="background:${p.color}18;color:${p.color}">${p.icon}</div>
         <div class="model-selected-info">
           <div class="model-selected-tier">${p.tier}</div>
           <div class="model-selected-name">${p.name}</div>
         </div>
         <svg class="model-selected-chevron" width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 6l4 4 4-4"/></svg>`
      : `<div class="model-selected-icon" style="background:var(--border);color:var(--text-muted)">
           <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M8 12h8"/></svg>
         </div>
         <div class="model-selected-info">
           <div class="model-selected-tier">Custom</div>
           <div class="model-selected-name">${modelId}</div>
         </div>
         <svg class="model-selected-chevron" width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 6l4 4 4-4"/></svg>`;
  };
  updateSelected(preset, settings.model);
  picker.appendChild(selected);

  // Dropdown
  const dropdown = el("div", "model-dropdown");

  MODEL_PRESETS.forEach((p) => {
    const opt = el("div", `model-option${p.id === settings.model ? " active" : ""}`);
    opt.innerHTML = `
      <div class="model-option-icon" style="background:${p.color}18;color:${p.color}">${p.icon}</div>
      <div class="model-option-info">
        <div class="model-option-tier">${p.tier} <span style="font-weight:400;color:var(--text-dim)">— ${p.name}</span></div>
        <div class="model-option-desc">${p.desc}</div>
      </div>`;
    opt.addEventListener("click", () => {
      settings.model = p.id;
      saveSettings(settings);
      updateSelected(p, p.id);
      picker.classList.remove("open");
      dropdown.querySelectorAll(".model-option").forEach((o) => o.classList.remove("active"));
      opt.classList.add("active");
    });
    dropdown.appendChild(opt);
  });

  // Custom model input row
  const customRow = el("div", "model-custom-row");
  const customInput = document.createElement("input");
  customInput.type = "text";
  customInput.placeholder = "org/model-name";
  customInput.value = findPreset(settings.model) ? "" : settings.model;
  const customBtn = document.createElement("button");
  customBtn.className = "secondary";
  customBtn.textContent = "Use";
  customBtn.addEventListener("click", () => {
    const val = customInput.value.trim();
    if (!val) return;
    settings.model = val;
    saveSettings(settings);
    updateSelected(undefined, val);
    picker.classList.remove("open");
    dropdown.querySelectorAll(".model-option").forEach((o) => o.classList.remove("active"));
  });
  customRow.appendChild(customInput);
  customRow.appendChild(customBtn);
  dropdown.appendChild(customRow);

  picker.appendChild(dropdown);

  // Toggle
  selected.addEventListener("click", () => picker.classList.toggle("open"));

  // Close on outside click
  document.addEventListener("click", (e) => {
    if (!picker.contains(e.target as Node)) picker.classList.remove("open");
  });

  return picker;
}

// --- Settings Panel ---
export function renderSettingsPanel(
  container: HTMLElement,
  settings: AppSettings,
  onChange: OnChange
): void {
  container.innerHTML = "";

  // ── Connection ──
  container.appendChild(groupHeading("Connection"));

  container.appendChild(label("Provider"));
  container.appendChild(fieldSelect(
    [["openrouter", "OpenRouter"], ["ollama", "Ollama"], ["openai-compatible", "OpenAI Compatible"]],
    settings.llmProvider,
    (v) => { settings.llmProvider = v as AppSettings["llmProvider"]; saveSettings(settings); onChange(settings); }
  ));

  container.appendChild(label("API Key"));
  container.appendChild(fieldInput("password", settings.apiKey, "sk-or-v1-...", (v) => { settings.apiKey = v; saveSettings(settings); }));

  if (settings.llmProvider !== "openrouter") {
    container.appendChild(label("Base URL"));
    container.appendChild(fieldInput("text", settings.baseURL, "http://localhost:11434", (v) => { settings.baseURL = v; saveSettings(settings); }));
  }

  container.appendChild(label("Model"));
  container.appendChild(renderModelPicker(settings, onChange));

  container.appendChild(divider());

  // ── Personas ──
  const personaHeader = el("div", "cfg-persona-header");
  const personaHeading = el("div", "cfg-group-heading");
  personaHeading.textContent = "Personas";
  personaHeader.appendChild(personaHeading);

  const personaBtns = el("div", "cfg-persona-btns");
  const addBtn = el("button", "cfg-btn-sm");
  addBtn.textContent = "+";
  addBtn.title = "Add persona";
  addBtn.addEventListener("click", () => {
    const updated = addPersona(settings);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  const resetBtn = el("button", "cfg-btn-sm");
  resetBtn.textContent = "Reset";
  resetBtn.title = "Reset to starter pack";
  resetBtn.addEventListener("click", () => {
    const updated = resetPersonas(settings);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  personaBtns.appendChild(addBtn);
  personaBtns.appendChild(resetBtn);
  personaHeader.appendChild(personaBtns);
  container.appendChild(personaHeader);

  settings.personas.forEach((persona) => {
    container.appendChild(renderPersonaCard(persona, settings, onChange));
  });

  container.appendChild(divider());

  // ── Tuning (collapsible) ──
  const tuningDetails = document.createElement("details");
  tuningDetails.className = "cfg-prompt-details";
  const tuningSummary = document.createElement("summary");
  tuningSummary.className = "cfg-prompt-summary";
  tuningSummary.textContent = "Tuning";
  tuningDetails.appendChild(tuningSummary);

  const tuningGrid = el("div", "cfg-tuning-grid");

  // Intensity
  const intCell = el("div", "cfg-cell");
  intCell.appendChild(fieldSelect(
    [["quiet", "Quiet"], ["balanced", "Balanced"], ["lively", "Lively"]],
    settings.intensity,
    (v) => { settings.intensity = v as AppSettings["intensity"]; saveSettings(settings); onChange(settings); }
  ));
  tuningGrid.appendChild(intCell);

  // Temperature
  const tempCell = el("div", "cfg-cell");
  tempCell.appendChild(fieldSlider("Temp", 0, 2, 0.1, settings.temperature, (v) => { settings.temperature = v; saveSettings(settings); }));
  tuningGrid.appendChild(tempCell);

  // Min Value
  const valCell = el("div", "cfg-cell");
  valCell.appendChild(fieldSlider("Min Value", 0, 1, 0.05, settings.minValueThreshold, (v) => { settings.minValueThreshold = v; saveSettings(settings); }));
  tuningGrid.appendChild(valCell);

  // Max Tokens
  const tokCell = el("div", "cfg-cell");
  tokCell.appendChild(fieldSlider("Tokens", 100, 2000, 50, settings.maxTokens, (v) => { settings.maxTokens = v; saveSettings(settings); }));
  tuningGrid.appendChild(tokCell);

  // Window Size
  const winCell = el("div", "cfg-cell");
  winCell.appendChild(fieldSlider("Window", 5, 50, 1, settings.windowSize, (v) => { settings.windowSize = v; saveSettings(settings); }));
  tuningGrid.appendChild(winCell);

  // Summary Refresh
  const sumCell = el("div", "cfg-cell");
  sumCell.appendChild(fieldSlider("Summary", 5, 30, 1, settings.summaryRefreshInterval, (v) => { settings.summaryRefreshInterval = v; saveSettings(settings); }));
  tuningGrid.appendChild(sumCell);

  tuningDetails.appendChild(tuningGrid);

  // Web search config (compact inline)
  if (settings.llmProvider === "openrouter") {
    const wsRow = el("div", "cfg-ws-row");
    const wsLabel = el("span", "cfg-ws-label");
    wsLabel.textContent = "Search";
    wsRow.appendChild(wsLabel);
    wsRow.appendChild(fieldSelect(
      [["auto", "Auto"], ["native", "Native"], ["exa", "Exa"], ["parallel", "Parallel"], ["firecrawl", "Firecrawl"]],
      settings.webSearchEngine,
      (v) => { settings.webSearchEngine = v as AppSettings["webSearchEngine"]; saveSettings(settings); }
    ));
    const maxLabel = el("span", "cfg-ws-label");
    maxLabel.textContent = "results";
    const maxInp = document.createElement("input");
    maxInp.type = "number";
    maxInp.min = "1";
    maxInp.max = "10";
    maxInp.value = String(settings.webSearchMaxResults);
    maxInp.className = "cfg-input cfg-input-narrow";
    maxInp.addEventListener("input", () => { settings.webSearchMaxResults = parseInt(maxInp.value) || 5; saveSettings(settings); });
    wsRow.appendChild(maxInp);
    wsRow.appendChild(maxLabel);
    tuningDetails.appendChild(wsRow);
  }

  container.appendChild(tuningDetails);

  // ── System Prompt (collapsible, usually don't need to see it) ──
  const promptDetails = document.createElement("details");
  promptDetails.className = "cfg-prompt-details";
  const promptSummary = document.createElement("summary");
  promptSummary.className = "cfg-prompt-summary";
  promptSummary.textContent = "System Prompt";
  promptDetails.appendChild(promptSummary);
  const promptArea = document.createElement("textarea");
  promptArea.className = "cfg-input cfg-prompt-textarea";
  promptArea.value = settings.systemPromptTemplate;
  promptArea.addEventListener("input", () => {
    settings.systemPromptTemplate = promptArea.value;
    saveSettings(settings);
  });
  promptDetails.appendChild(promptArea);
  container.appendChild(promptDetails);

  container.appendChild(divider());

  // ── Export ──
  const exportBtn = el("button", "cfg-btn-export");
  exportBtn.textContent = "Export Settings JSON";
  exportBtn.addEventListener("click", () => {
    const json = exportSettingsJSON(settings);
    const blob = new Blob([json], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "sidecast-preset.json";
    a.click();
    URL.revokeObjectURL(url);
  });
  container.appendChild(exportBtn);
}

// --- Persona Card ---
function renderPersonaCard(
  persona: SidecastPersona,
  settings: AppSettings,
  onChange: OnChange
): HTMLElement {
  const card = el("div", `persona-card${persona.isEnabled ? "" : " disabled"}`);

  // Top row: dot + name + controls
  const row = el("div", "persona-row");

  const dot = el("div", "persona-dot");
  dot.style.background = persona.avatarTint;
  if (persona.avatarEmoji) {
    dot.textContent = persona.avatarEmoji;
  }
  row.appendChild(dot);

  const info = el("div", "persona-info");
  info.innerHTML = `<span class="persona-name">${persona.name}</span><span class="persona-subtitle">${persona.subtitle}</span>`;
  info.style.cursor = "pointer";
  row.appendChild(info);

  // Controls cluster
  const controls = el("div", "persona-controls");

  if (settings.llmProvider === "openrouter") {
    const webPill = el("button", `persona-web-pill${persona.webSearchEnabled ? " on" : ""}`);
    webPill.textContent = "Web";
    webPill.title = "Toggle web search for this persona";
    webPill.addEventListener("click", () => {
      persona.webSearchEnabled = !persona.webSearchEnabled;
      webPill.className = `persona-web-pill${persona.webSearchEnabled ? " on" : ""}`;
      saveSettings(settings);
    });
    controls.appendChild(webPill);
  }

  const enablePill = el("button", `persona-enable-pill${persona.isEnabled ? " on" : ""}`);
  enablePill.textContent = persona.isEnabled ? "ON" : "OFF";
  enablePill.title = "Enable or disable this persona";
  enablePill.addEventListener("click", () => {
    persona.isEnabled = !persona.isEnabled;
    enablePill.className = `persona-enable-pill${persona.isEnabled ? " on" : ""}`;
    enablePill.textContent = persona.isEnabled ? "ON" : "OFF";
    card.className = `persona-card${persona.isEnabled ? "" : " disabled"}`;
    saveSettings(settings);
  });
  controls.appendChild(enablePill);

  const delBtn = el("button", "persona-icon-btn danger");
  delBtn.textContent = "\u00D7";
  delBtn.addEventListener("click", () => {
    const updated = removePersona(settings, persona.id);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  controls.appendChild(delBtn);

  row.appendChild(controls);
  card.appendChild(row);

  // Expandable edit area
  const editDiv = el("div", "persona-edit");
  editDiv.style.display = "none";

  const fields: [string, "name" | "subtitle" | "prompt", "text" | "textarea"][] = [
    ["Name", "name", "text"],
    ["Subtitle", "subtitle", "text"],
    ["Prompt", "prompt", "textarea"],
  ];

  fields.forEach(([lbl, key, type]) => {
    editDiv.appendChild(label(lbl));
    if (type === "textarea") {
      const ta = document.createElement("textarea");
      ta.className = "cfg-input";
      ta.value = persona[key];
      ta.addEventListener("input", () => {
        (persona as any)[key] = ta.value;
        saveSettings(settings);
      });
      editDiv.appendChild(ta);
    } else {
      editDiv.appendChild(fieldInput("text", persona[key], "", (v) => {
        (persona as any)[key] = v;
        saveSettings(settings);
        info.innerHTML = `<span class="persona-name">${persona.name}</span><span class="persona-subtitle">${persona.subtitle}</span>`;
      }));
    }
  });

  // Avatar row — emoji + color
  const avatarRow = el("div", "persona-behavior");
  const emojiCell = el("div", "persona-behavior-cell");
  emojiCell.appendChild(label("Emoji"));
  const emojiInp = document.createElement("input");
  emojiInp.type = "text";
  emojiInp.className = "cfg-input";
  emojiInp.value = persona.avatarEmoji || "";
  emojiInp.style.width = "50px";
  emojiInp.style.textAlign = "center";
  emojiInp.style.fontSize = "16px";
  emojiInp.addEventListener("input", () => {
    persona.avatarEmoji = emojiInp.value;
    dot.textContent = emojiInp.value;
    saveSettings(settings);
  });
  emojiCell.appendChild(emojiInp);
  avatarRow.appendChild(emojiCell);

  const colorCell = el("div", "persona-behavior-cell");
  colorCell.appendChild(label("Color"));
  const colorInp = document.createElement("input");
  colorInp.type = "color";
  colorInp.className = "cfg-input";
  colorInp.value = persona.avatarTint;
  colorInp.style.width = "50px";
  colorInp.style.height = "28px";
  colorInp.style.padding = "1px";
  colorInp.addEventListener("input", () => {
    persona.avatarTint = colorInp.value;
    dot.style.background = colorInp.value;
    saveSettings(settings);
  });
  colorCell.appendChild(colorInp);
  avatarRow.appendChild(colorCell);
  editDiv.appendChild(avatarRow);

  // Behavior row — compact inline selects
  const behaviorRow = el("div", "persona-behavior");
  const selects: [string, "verbosity" | "cadence" | "evidencePolicy", readonly string[]][] = [
    ["Verbosity", "verbosity", ["terse", "short", "medium"]],
    ["Cadence", "cadence", ["rare", "normal", "active"]],
    ["Evidence", "evidencePolicy", ["required", "preferred", "optional"]],
  ];
  selects.forEach(([lbl, key, opts]) => {
    const cell = el("div", "persona-behavior-cell");
    cell.appendChild(label(lbl));
    const sel = document.createElement("select");
    sel.className = "cfg-input";
    opts.forEach((o) => {
      const opt = document.createElement("option");
      opt.value = o;
      opt.textContent = o;
      opt.selected = persona[key] === o;
      sel.appendChild(opt);
    });
    sel.addEventListener("change", () => {
      (persona as any)[key] = sel.value;
      saveSettings(settings);
    });
    cell.appendChild(sel);
    behaviorRow.appendChild(cell);
  });
  editDiv.appendChild(behaviorRow);

  card.appendChild(editDiv);

  // Toggle edit on click
  info.addEventListener("click", () => {
    editDiv.style.display = editDiv.style.display === "none" ? "block" : "none";
  });

  return card;
}

// --- Transcript Viewer ---
export function renderTranscriptViewer(
  container: HTMLElement,
  segments: { start: number; duration: number; text: string }[],
  activeIndex: number,
  onClickSegment: (time: number) => void
): void {
  container.innerHTML = "";
  segments.forEach((seg, i) => {
    const div = document.createElement("div");
    div.className = `transcript-seg${i === activeIndex ? " active" : i > activeIndex ? " future" : ""}`;

    const minutes = Math.floor(seg.start / 60);
    const seconds = Math.floor(seg.start % 60);
    const ts = `${minutes}:${seconds.toString().padStart(2, "0")}`;

    div.innerHTML = `<span class="ts">${ts}</span>${seg.text}`;
    div.addEventListener("click", () => onClickSegment(seg.start));
    container.appendChild(div);

    if (i === activeIndex) {
      requestAnimationFrame(() => div.scrollIntoView({ block: "center", behavior: "smooth" }));
    }
  });
}

// --- Sidecast Output ---
export function renderSidecastBubbles(
  container: HTMLElement,
  messages: { personaName: string; text: string; confidence: number; priority: number; value: number; personaId: string }[],
  personas: SidecastPersona[]
): void {
  container.innerHTML = "";
  const personaById = new Map(personas.map((p) => [p.id, p]));

  messages.forEach((msg) => {
    const persona = personaById.get(msg.personaId);
    const tint = persona?.avatarTint ?? "#666";

    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.style.borderColor = tint + "30";
    bubble.style.background = tint + "10";
    const emoji = persona?.avatarEmoji ?? "";
    bubble.innerHTML = `
      <div class="bubble-header">
        <span class="bubble-name" style="color:${tint}">${emoji ? emoji + " " : ""}${msg.personaName}</span>
        <span class="bubble-meta">v:${msg.value.toFixed(2)} p:${msg.priority.toFixed(2)} c:${msg.confidence.toFixed(2)}</span>
      </div>
      <div class="bubble-text">${escapeHtml(msg.text)}</div>
    `;
    container.appendChild(bubble);
  });
}

function formatVideoTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function escapeHtml(text: string): string {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

export function renderDebugLog(
  container: HTMLElement,
  entries: DebugLogEntry[]
): void {
  container.innerHTML = "";

  if (entries.length === 0) return;

  const heading = document.createElement("h2");
  heading.textContent = "Debug Log";
  heading.style.marginTop = "16px";
  container.appendChild(heading);

  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    const r = entry.result;

    const node = document.createElement("details");
    node.className = "debug-entry";
    if (i === entries.length - 1) node.open = true;

    const summary = document.createElement("summary");
    summary.className = "debug-entry-summary";

    const badge = r.skipped ? "skip" : r.accepted.length > 0 ? "ok" : "empty";
    const badgeLabel = r.skipped
      ? "cooldown"
      : `${r.accepted.length} shown, ${r.filtered.length} filtered`;

    const webTag = r.webSearchUsed ? `<span class="debug-badge debug-badge-web">web</span>` : "";

    summary.innerHTML =
      `<span class="debug-badge debug-badge-${badge}">${badgeLabel}</span>` +
      webTag +
      `<span class="debug-time">${formatVideoTime(entry.timestamp)}</span>` +
      `<span class="debug-wall">${entry.wallTime.toLocaleTimeString()}</span>` +
      `<span class="debug-chars">${r.promptCharCount > 0 ? `~${r.promptCharCount} chars` : ""}</span>`;
    node.appendChild(summary);

    const body = document.createElement("div");
    body.className = "debug-entry-body";

    if (!r.skipped) {
      const sysDetails = document.createElement("details");
      sysDetails.className = "debug-sub";
      sysDetails.innerHTML =
        `<summary class="debug-sub-summary">System Prompt</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.systemPrompt)}</pre>`;
      body.appendChild(sysDetails);

      const userDetails = document.createElement("details");
      userDetails.className = "debug-sub";
      userDetails.innerHTML =
        `<summary class="debug-sub-summary">User Prompt</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.userPrompt)}</pre>`;
      body.appendChild(userDetails);

      const respDetails = document.createElement("details");
      respDetails.className = "debug-sub";
      respDetails.innerHTML =
        `<summary class="debug-sub-summary">LLM Response</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.rawResponse)}</pre>`;
      body.appendChild(respDetails);

      if (r.citations.length > 0) {
        const citDetails = document.createElement("details");
        citDetails.className = "debug-sub";
        let citHtml = `<summary class="debug-sub-summary">Web Citations (${r.citations.length})</summary><div style="padding:4px 0">`;
        r.citations.forEach((c) => {
          const domain = new URL(c.url).hostname;
          citHtml += `<div class="debug-citation">`;
          citHtml += `<a href="${escapeHtml(c.url)}" target="_blank" class="debug-citation-link">${escapeHtml(c.title || domain)}</a>`;
          citHtml += `<span class="debug-citation-domain">${escapeHtml(domain)}</span>`;
          if (c.content) citHtml += `<div class="debug-citation-snippet">${escapeHtml(c.content.slice(0, 200))}${c.content.length > 200 ? "..." : ""}</div>`;
          citHtml += `</div>`;
        });
        citHtml += `</div>`;
        citDetails.innerHTML = citHtml;
        body.appendChild(citDetails);
      }

      if (r.accepted.length > 0) {
        const accDiv = document.createElement("div");
        accDiv.className = "debug-section-label";
        accDiv.textContent = "Accepted:";
        body.appendChild(accDiv);
        r.accepted.forEach((msg) => {
          const line = document.createElement("div");
          line.className = "debug-accepted";
          line.innerHTML =
            `<strong>${escapeHtml(msg.personaName)}</strong> ` +
            `<span class="debug-meta">v:${msg.value.toFixed(2)} p:${msg.priority.toFixed(2)} c:${msg.confidence.toFixed(2)}</span><br>` +
            `${escapeHtml(msg.text)}`;
          body.appendChild(line);
        });
      }

      if (r.filtered.length > 0) {
        const filtDiv = document.createElement("div");
        filtDiv.className = "debug-section-label";
        filtDiv.textContent = "Filtered:";
        body.appendChild(filtDiv);
        r.filtered.forEach((f) => {
          const line = document.createElement("div");
          line.className = "filter-log";
          line.textContent = `[${f.personaName}] ${f.reason} — "${f.text.slice(0, 80)}"`;
          body.appendChild(line);
        });
      }
    }

    node.appendChild(body);
    container.appendChild(node);
  }
}

export function setStatus(state: "ok" | "error" | "loading", text: string): void {
  const dot = document.getElementById("status-dot")!;
  const span = document.getElementById("status-text")!;
  dot.className = `status-dot ${state}`;
  span.textContent = text;
}
