import type { AppSettings, SidecastPersona } from "./types.ts";
import { saveSettings, addPersona, removePersona, resetPersonas } from "./settings.ts";

type OnChange = (settings: AppSettings) => void;

export function renderSettingsPanel(
  container: HTMLElement,
  settings: AppSettings,
  onChange: OnChange
): void {
  container.innerHTML = "";

  const h = (tag: string, attrs?: Record<string, string>, ...children: (string | HTMLElement)[]) => {
    const el = document.createElement(tag);
    if (attrs) Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
    children.forEach((c) => (typeof c === "string" ? (el.innerHTML += c) : el.appendChild(c)));
    return el;
  };

  function section(title: string, content: HTMLElement, collapsed = false): HTMLElement {
    const sec = h("div", { class: `section${collapsed ? " collapsed" : ""}` });
    const header = h("div", { class: "section-header" }, title);
    header.addEventListener("click", () => sec.classList.toggle("collapsed"));
    sec.appendChild(header);
    const body = h("div", { class: "section-body" });
    body.appendChild(content);
    sec.appendChild(body);
    return sec;
  }

  function inputRow(label: string, type: string, value: string, onInput: (v: string) => void): HTMLElement {
    const row = h("div", {});
    row.appendChild(h("label", {}, label));
    const inp = document.createElement("input");
    inp.type = type;
    inp.value = value;
    inp.addEventListener("input", () => {
      onInput(inp.value);
      saveSettings(settings);
    });
    row.appendChild(inp);
    return row;
  }

  function selectRow(label: string, options: [string, string][], value: string, onSelect: (v: string) => void): HTMLElement {
    const row = h("div", {});
    row.appendChild(h("label", {}, label));
    const sel = document.createElement("select");
    options.forEach(([val, text]) => {
      const opt = document.createElement("option");
      opt.value = val;
      opt.textContent = text;
      opt.selected = val === value;
      sel.appendChild(opt);
    });
    sel.addEventListener("change", () => {
      onSelect(sel.value);
      saveSettings(settings);
    });
    row.appendChild(sel);
    return row;
  }

  function sliderRow(label: string, min: number, max: number, step: number, value: number, onInput: (v: number) => void): HTMLElement {
    const row = h("div", { class: "slider-row" });
    row.appendChild(h("label", { style: "min-width:100px" }, label));
    const inp = document.createElement("input");
    inp.type = "range";
    inp.min = String(min);
    inp.max = String(max);
    inp.step = String(step);
    inp.value = String(value);
    const valSpan = h("span", { class: "slider-val" }, String(value));
    inp.addEventListener("input", () => {
      const v = parseFloat(inp.value);
      valSpan.textContent = String(v);
      onInput(v);
      saveSettings(settings);
    });
    row.appendChild(inp);
    row.appendChild(valSpan);
    return row;
  }

  // LLM section
  const llmBody = h("div", {});
  llmBody.appendChild(
    selectRow("Provider", [["openrouter", "OpenRouter"], ["ollama", "Ollama"], ["openai-compatible", "OpenAI Compatible"]], settings.llmProvider, (v) => {
      settings.llmProvider = v as AppSettings["llmProvider"];
      onChange(settings);
    })
  );
  llmBody.appendChild(inputRow("API Key", "password", settings.apiKey, (v) => (settings.apiKey = v)));
  llmBody.appendChild(inputRow("Base URL", "text", settings.baseURL, (v) => (settings.baseURL = v)));
  llmBody.appendChild(inputRow("Model", "text", settings.model, (v) => (settings.model = v)));
  llmBody.appendChild(sliderRow("Temperature", 0, 2, 0.1, settings.temperature, (v) => (settings.temperature = v)));
  llmBody.appendChild(sliderRow("Max Tokens", 100, 2000, 50, settings.maxTokens, (v) => (settings.maxTokens = v)));
  container.appendChild(section("LLM", llmBody));

  // Context section
  const ctxBody = h("div", {});
  ctxBody.appendChild(
    selectRow("Context Mode", [["full", "Full Transcript"], ["window", "Rolling Window"], ["summary-recent", "Summary + Recent"]], settings.contextMode, (v) => {
      settings.contextMode = v as AppSettings["contextMode"];
      onChange(settings);
    })
  );
  ctxBody.appendChild(sliderRow("Window Size", 5, 50, 1, settings.windowSize, (v) => (settings.windowSize = v)));
  ctxBody.appendChild(sliderRow("Summary Refresh", 5, 30, 1, settings.summaryRefreshInterval, (v) => (settings.summaryRefreshInterval = v)));
  ctxBody.appendChild(sliderRow("Full Mode Limit", 1000, 16000, 500, settings.fullModeCharLimit, (v) => (settings.fullModeCharLimit = v)));
  container.appendChild(section("Context", ctxBody));

  // Sidecast section
  const scBody = h("div", {});
  scBody.appendChild(
    selectRow("Intensity", [["quiet", "Quiet"], ["balanced", "Balanced"], ["lively", "Lively"]], settings.intensity, (v) => {
      settings.intensity = v as AppSettings["intensity"];
      onChange(settings);
    })
  );
  const toggleDiv = h("div", { class: "toggle", style: "margin:8px 0" });
  const ffCheck = document.createElement("input");
  ffCheck.type = "checkbox";
  ffCheck.checked = settings.forceFire;
  ffCheck.addEventListener("change", () => {
    settings.forceFire = ffCheck.checked;
    saveSettings(settings);
  });
  toggleDiv.appendChild(ffCheck);
  toggleDiv.appendChild(h("span", {}, "Force-fire (bypass cooldowns)"));
  scBody.appendChild(toggleDiv);

  const promptLabel = h("label", {}, "System Prompt Template");
  scBody.appendChild(promptLabel);
  const promptArea = document.createElement("textarea");
  promptArea.value = settings.systemPromptTemplate;
  promptArea.style.minHeight = "120px";
  promptArea.addEventListener("input", () => {
    settings.systemPromptTemplate = promptArea.value;
    saveSettings(settings);
  });
  scBody.appendChild(promptArea);
  container.appendChild(section("Sidecast", scBody));

  // Personas section
  const personasBody = h("div", {});
  settings.personas.forEach((persona, idx) => {
    const card = renderPersonaCard(persona, settings, idx, onChange);
    personasBody.appendChild(card);
  });
  const btnRow = h("div", { style: "display:flex;gap:4px;margin-top:8px" });
  const addBtn = h("button", { class: "secondary" }, "Add Persona");
  addBtn.addEventListener("click", () => {
    const updated = addPersona(settings);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  const resetBtn = h("button", { class: "secondary" }, "Reset Starter Pack");
  resetBtn.addEventListener("click", () => {
    const updated = resetPersonas(settings);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  btnRow.appendChild(addBtn);
  btnRow.appendChild(resetBtn);
  personasBody.appendChild(btnRow);
  container.appendChild(section("Personas", personasBody));
}

function renderPersonaCard(
  persona: SidecastPersona,
  settings: AppSettings,
  _idx: number,
  onChange: OnChange
): HTMLElement {
  const card = document.createElement("div");
  card.className = "persona-card";
  card.style.flexWrap = "wrap";

  const dot = document.createElement("div");
  dot.className = "persona-dot";
  dot.style.background = persona.avatarTint;
  card.appendChild(dot);

  const info = document.createElement("div");
  info.className = "persona-info";
  info.innerHTML = `<div class="persona-name">${persona.name}</div><div class="persona-subtitle">${persona.subtitle}</div>`;
  card.appendChild(info);

  const toggle = document.createElement("input");
  toggle.type = "checkbox";
  toggle.checked = persona.isEnabled;
  toggle.addEventListener("change", () => {
    persona.isEnabled = toggle.checked;
    saveSettings(settings);
  });
  card.appendChild(toggle);

  const delBtn = document.createElement("button");
  delBtn.className = "secondary";
  delBtn.textContent = "x";
  delBtn.style.padding = "2px 6px";
  delBtn.addEventListener("click", () => {
    const updated = removePersona(settings, persona.id);
    Object.assign(settings, updated);
    saveSettings(settings);
    onChange(settings);
  });
  card.appendChild(delBtn);

  // Expandable edit fields
  const editDiv = document.createElement("div");
  editDiv.style.cssText = "width:100%;display:none;margin-top:6px;";
  const fields = [
    ["Name", "name", "text"],
    ["Subtitle", "subtitle", "text"],
    ["Prompt", "prompt", "textarea"],
  ] as const;

  fields.forEach(([label, key, type]) => {
    const lbl = document.createElement("label");
    lbl.textContent = label;
    lbl.style.marginTop = "4px";
    editDiv.appendChild(lbl);
    if (type === "textarea") {
      const ta = document.createElement("textarea");
      ta.value = persona[key];
      ta.addEventListener("input", () => {
        (persona as any)[key] = ta.value;
        saveSettings(settings);
      });
      editDiv.appendChild(ta);
    } else {
      const inp = document.createElement("input");
      inp.type = "text";
      inp.value = persona[key];
      inp.addEventListener("input", () => {
        (persona as any)[key] = inp.value;
        saveSettings(settings);
        info.innerHTML = `<div class="persona-name">${persona.name}</div><div class="persona-subtitle">${persona.subtitle}</div>`;
      });
      editDiv.appendChild(inp);
    }
  });

  // Behavior dropdowns
  const selects = [
    ["Verbosity", "verbosity", ["terse", "short", "medium"]],
    ["Cadence", "cadence", ["rare", "normal", "active"]],
    ["Evidence", "evidencePolicy", ["required", "preferred", "optional"]],
  ] as const;
  selects.forEach(([label, key, opts]) => {
    const lbl = document.createElement("label");
    lbl.textContent = label;
    lbl.style.marginTop = "4px";
    editDiv.appendChild(lbl);
    const sel = document.createElement("select");
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
    editDiv.appendChild(sel);
  });

  card.appendChild(editDiv);

  // Toggle edit on click info area
  info.style.cursor = "pointer";
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
    div.className = `transcript-seg${i === activeIndex ? " active" : ""}`;

    const minutes = Math.floor(seg.start / 60);
    const seconds = Math.floor(seg.start % 60);
    const ts = `${minutes}:${seconds.toString().padStart(2, "0")}`;

    div.innerHTML = `<span class="ts">${ts}</span>${seg.text}`;
    div.addEventListener("click", () => onClickSegment(seg.start));
    container.appendChild(div);

    if (i === activeIndex) {
      // Auto-scroll to active
      requestAnimationFrame(() => div.scrollIntoView({ block: "center", behavior: "smooth" }));
    }
  });
}

// --- Sidecast Output ---
export function renderSidecastBubbles(
  container: HTMLElement,
  messages: { personaName: string; text: string; confidence: number; priority: number; personaId: string }[],
  personas: SidecastPersona[]
): void {
  container.innerHTML = "";
  const personaById = new Map(personas.map((p) => [p.id, p]));

  messages.forEach((msg) => {
    const persona = personaById.get(msg.personaId);
    const tint = persona?.avatarTint ?? "#666";

    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.style.borderLeftColor = tint;
    bubble.innerHTML = `
      <div class="bubble-header">
        <span class="bubble-name" style="color:${tint}">${msg.personaName}</span>
        <span class="bubble-meta">p:${msg.priority.toFixed(2)} c:${msg.confidence.toFixed(2)}</span>
      </div>
      <div class="bubble-text">${msg.text}</div>
    `;
    container.appendChild(bubble);
  });
}

export function renderFilterLog(
  container: HTMLElement,
  filtered: { personaName: string; text: string; reason: string }[],
  promptCharCount: number
): void {
  container.innerHTML = `<div class="debug-info">Prompt: ~${promptCharCount} chars</div>`;
  filtered.forEach((f) => {
    const div = document.createElement("div");
    div.className = "filter-log";
    div.textContent = `[${f.personaName}] filtered: ${f.reason} — "${f.text.slice(0, 60)}..."`;
    container.appendChild(div);
  });
}

export function setStatus(state: "ok" | "error" | "loading", text: string): void {
  const dot = document.getElementById("status-dot")!;
  const span = document.getElementById("status-text")!;
  dot.className = `status-dot ${state}`;
  span.textContent = text;
}
