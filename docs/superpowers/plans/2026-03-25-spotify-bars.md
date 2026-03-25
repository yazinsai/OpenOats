# Spotify-Style Audio Bars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the smooth sine wave in `WaveformVisualizer` with Spotify-style animated vertical bars that bounce at audio-level-proportional heights.

**Architecture:** Single-file change — `WaveformVisualizer.tsx`. Remove the `useState`/`setInterval` data-generation pattern and the two-effect draw loop; replace with one `useEffect` that runs a `requestAnimationFrame` loop drawing 3 vertical bars anchored at the canvas bottom. A `useRef` stores the animation frame ID for safe cancellation across renders.

**Tech Stack:** React, TypeScript, Canvas 2D API (`requestAnimationFrame`, `roundRect`)

---

## File Map

| File | Action |
|------|--------|
| `opencassava/src/components/WaveformVisualizer.tsx` | Modify — replace drawing logic |

No other files change.

---

### Task 1: Replace `WaveformVisualizer` drawing logic

**Files:**
- Modify: `opencassava/src/components/WaveformVisualizer.tsx`

This is a canvas-based visual component in a Tauri desktop app — no automated test framework exists for rendering. Verification is visual: run the dev server and observe the bars animate when audio is active and show stubs when silent.

**Bar geometry constants (for reference during implementation):**

```
canvas width:  140px
canvas height: 18px
bar width:     6px
bar gap:       4px
bar stride:    10px  (6 + 4)
cluster width: 26px  (3 bars × 6 + 2 gaps × 4)
x of bar 0:   57px  ((140 - 26) / 2)
x of bar i:   57 + i * 10
max height:   14px
silence height: 3px
y of bar:     18 - barHeight  (anchored at bottom)
```

**Phase/speed table:**

| Bar i | speed | phase      |
|-------|-------|------------|
| 0     | 1.0   | 0          |
| 1     | 1.4   | Math.PI/3  |
| 2     | 0.8   | 2*Math.PI/3|

- [ ] **Step 1: Open the file and understand the current structure**

Read `opencassava/src/components/WaveformVisualizer.tsx`.

Current structure:
- Lines 1–2: imports (`useState`, `useEffect`, `useRef`, `colors`)
- Lines 18: `dataArray` state (`useState<Float32Array>`)
- Lines 25–41: First `useEffect` — generates `dataArray` via `setInterval` every 50ms
- Lines 44–139: Second `useEffect` — draws the waveform via `requestAnimationFrame`, depends on `dataArray`
- Lines 141–154: JSX `<canvas>` element (unchanged)

- [ ] **Step 2: Rewrite `WaveformVisualizer.tsx`**

Replace the entire file content with the following:

```tsx
import { useEffect, useRef } from "react";
import { colors } from "../theme";

interface Props {
  level: number; // 0-1
  isActive: boolean;
  color?: string;
  colorLight?: string;
}

const BAR_COUNT = 3;
const BAR_WIDTH = 6;
const BAR_GAP = 4;
const BAR_STRIDE = BAR_WIDTH + BAR_GAP;
const CLUSTER_WIDTH = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP;
const MAX_BAR_HEIGHT = 14;
const SILENCE_BAR_HEIGHT = 3;
const CORNER_RADIUS = 2;

const BAR_CONFIGS = [
  { speed: 1.0, phase: 0 },
  { speed: 1.4, phase: Math.PI / 3 },
  { speed: 0.8, phase: (2 * Math.PI) / 3 },
];

export function WaveformVisualizer({
  level,
  isActive,
  color = colors.accent,
  colorLight: _colorLight = colors.accentLight,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const animFrameRef = useRef<number>(0);
  const width = 140;
  const height = 18;
  const normalizedLevel = Math.max(0, Math.min(1, (level - 0.015) / 0.985));
  const visualLevel = Math.pow(normalizedLevel, 0.65);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const startX = (width - CLUSTER_WIDTH) / 2; // 57px

    const drawRoundedBar = (x: number, barHeight: number, fillColor: string) => {
      const y = height - barHeight;
      ctx.fillStyle = fillColor;
      ctx.beginPath();
      ctx.roundRect(x, y, BAR_WIDTH, barHeight, CORNER_RADIUS);
      ctx.fill();
    };

    const isSilent = !isActive || normalizedLevel < 0.02;

    if (isSilent) {
      cancelAnimationFrame(animFrameRef.current);
      ctx.clearRect(0, 0, width, height);
      for (let i = 0; i < BAR_COUNT; i++) {
        drawRoundedBar(startX + i * BAR_STRIDE, SILENCE_BAR_HEIGHT, colors.border);
      }
      return;
    }

    const loop = () => {
      ctx.clearRect(0, 0, width, height);
      const t = performance.now() / 300;
      for (let i = 0; i < BAR_COUNT; i++) {
        const { speed, phase } = BAR_CONFIGS[i];
        const barHeight = Math.max(
          SILENCE_BAR_HEIGHT,
          visualLevel * MAX_BAR_HEIGHT * (0.6 + 0.4 * Math.sin(t * speed + phase))
        );
        drawRoundedBar(startX + i * BAR_STRIDE, barHeight, color);
      }
      animFrameRef.current = requestAnimationFrame(loop);
    };

    animFrameRef.current = requestAnimationFrame(loop);

    return () => cancelAnimationFrame(animFrameRef.current);
  }, [level, isActive, color, normalizedLevel, visualLevel]);

  return (
    <canvas
      ref={canvasRef}
      width={width}
      height={height}
      style={{
        width,
        height,
        borderRadius: 4,
        background: colors.surfaceElevated,
      }}
    />
  );
}
```

- [ ] **Step 3: Verify TypeScript compiles**

Run from `opencassava/`:
```bash
npx tsc --noEmit
```
Expected: no errors. If you see "Property 'roundRect' does not exist on type 'CanvasRenderingContext2D'", add `"lib": ["ES2022", "DOM"]` to `tsconfig.json` (check existing tsconfig first — it may already have DOM).

- [ ] **Step 4: Start the dev server and visually verify**

Run from `opencassava/`:
```bash
npm run tauri dev
```

Checklist:
- [ ] Before recording: no bars visible (control bar hides the waveform area when not running)
- [ ] After clicking Record: 3 bars animate independently when you speak into the mic (teal bars)
- [ ] "Them" bars animate in amber when system audio is active
- [ ] When mic is silent: 3 short gray stubs visible, no animation
- [ ] Bars stop animating when recording is stopped

- [ ] **Step 5: Commit**

```bash
git add opencassava/src/components/WaveformVisualizer.tsx
git commit -m "feat: replace sine wave with spotify-style animated bars"
```
