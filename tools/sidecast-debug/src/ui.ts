import type { AppSettings, SidecastPersona, DebugLogEntry } from "./types.ts";
import { saveSettings, addPersona, removePersona, resetPersonas } from "./settings.ts";

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
  {
    const MODEL_PRESETS: [string, string][] = [
      ["google/gemini-3.1-flash-lite-preview", "Quick — Gemini Flash Lite"],
      ["x-ai/grok-4.1-fast", "Sharp — Grok 4.1 Fast"],
      ["openai/gpt-5.4", "Genius — GPT-5.4"],
    ];
    const wrap = el("div", "cfg-combo");
    const input = document.createElement("input");
    input.type = "text";
    input.className = "cfg-input cfg-combo-input";
    input.value = settings.model;
    input.placeholder = "org/model-name";
    input.setAttribute("list", "model-presets");
    input.addEventListener("input", () => { settings.model = input.value; saveSettings(settings); });
    const datalist = document.createElement("datalist");
    datalist.id = "model-presets";
    MODEL_PRESETS.forEach(([value, label]) => {
      const opt = document.createElement("option");
      opt.value = value;
      opt.label = label;
      datalist.appendChild(opt);
    });
    wrap.appendChild(input);
    wrap.appendChild(datalist);
    container.appendChild(wrap);
  }

  container.appendChild(divider());

  // ── Tuning ──
  container.appendChild(groupHeading("Tuning"));

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

  container.appendChild(tuningGrid);

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
    container.appendChild(wsRow);
  }

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
    bubble.innerHTML = `
      <div class="bubble-header">
        <span class="bubble-name" style="color:${tint}">${msg.personaName}</span>
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
