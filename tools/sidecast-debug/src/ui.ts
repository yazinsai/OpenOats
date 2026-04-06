import type { AppSettings, SidecastPersona, DebugLogEntry } from "./types.ts";
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
  ctxBody.appendChild(sliderRow("Window Size", 5, 50, 1, settings.windowSize, (v) => (settings.windowSize = v)));
  ctxBody.appendChild(sliderRow("Summary Refresh", 5, 30, 1, settings.summaryRefreshInterval, (v) => (settings.summaryRefreshInterval = v)));
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

  scBody.appendChild(sliderRow("Min Value", 0, 1, 0.05, settings.minValueThreshold, (v) => (settings.minValueThreshold = v)));

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

  // Web Search section
  const wsBody = h("div", {});
  wsBody.appendChild(
    selectRow("Engine", [["auto", "Auto (native or Exa)"], ["native", "Native"], ["exa", "Exa"], ["parallel", "Parallel"], ["firecrawl", "Firecrawl"]], settings.webSearchEngine, (v) => {
      settings.webSearchEngine = v as AppSettings["webSearchEngine"];
      saveSettings(settings);
    })
  );
  wsBody.appendChild(sliderRow("Max Results", 1, 10, 1, settings.webSearchMaxResults, (v) => (settings.webSearchMaxResults = v)));
  wsBody.appendChild(h("div", { style: "font-size:11px;color:var(--text-muted);margin-top:4px" }, "Toggle web search per persona below. Only applies to OpenRouter."));
  container.appendChild(section("Web Search", wsBody));

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
  toggle.title = "Enable persona";
  toggle.addEventListener("change", () => {
    persona.isEnabled = toggle.checked;
    saveSettings(settings);
  });
  card.appendChild(toggle);

  const webBtn = document.createElement("button");
  webBtn.className = "secondary";
  webBtn.textContent = persona.webSearchEnabled ? "🔍" : "—";
  webBtn.title = persona.webSearchEnabled ? "Web search: ON (click to disable)" : "Web search: OFF (click to enable)";
  webBtn.style.cssText = "padding:2px 6px;font-size:12px;min-width:24px;";
  webBtn.addEventListener("click", () => {
    persona.webSearchEnabled = !persona.webSearchEnabled;
    webBtn.textContent = persona.webSearchEnabled ? "🔍" : "—";
    webBtn.title = persona.webSearchEnabled ? "Web search: ON (click to disable)" : "Web search: OFF (click to enable)";
    saveSettings(settings);
  });
  card.appendChild(webBtn);

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
    bubble.style.borderLeftColor = tint;
    bubble.innerHTML = `
      <div class="bubble-header">
        <span class="bubble-name" style="color:${tint}">${msg.personaName}</span>
        <span class="bubble-meta">v:${msg.value.toFixed(2)} p:${msg.priority.toFixed(2)} c:${msg.confidence.toFixed(2)}</span>
      </div>
      <div class="bubble-text">${msg.text}</div>
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

  // Render newest first
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    const r = entry.result;

    const node = document.createElement("details");
    node.className = "debug-entry";
    // Auto-open the most recent entry
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
      // System prompt
      const sysDetails = document.createElement("details");
      sysDetails.className = "debug-sub";
      sysDetails.innerHTML =
        `<summary class="debug-sub-summary">System Prompt</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.systemPrompt)}</pre>`;
      body.appendChild(sysDetails);

      // User prompt
      const userDetails = document.createElement("details");
      userDetails.className = "debug-sub";
      userDetails.innerHTML =
        `<summary class="debug-sub-summary">User Prompt</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.userPrompt)}</pre>`;
      body.appendChild(userDetails);

      // Raw response
      const respDetails = document.createElement("details");
      respDetails.className = "debug-sub";
      respDetails.innerHTML =
        `<summary class="debug-sub-summary">LLM Response</summary>` +
        `<pre class="debug-pre">${escapeHtml(r.rawResponse)}</pre>`;
      body.appendChild(respDetails);

      // Web search citations
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

      // Accepted messages
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

      // Filtered candidates
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
