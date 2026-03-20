# Them Waveform Visualizer — Design Spec

**Date:** 2026-03-20
**Status:** Approved

## Problem

The control bar shows a waveform for the microphone ("you") while recording, but the "them" (system/speaker) audio level is already captured and emitted by the backend — it's simply never visualized. Users have no feedback that speaker audio is being picked up.

## Goal

Add a second waveform for the "them" audio, stacked vertically below the existing "you" waveform, using a distinct color.

## Constraints

- No new components needed — reuse `WaveformVisualizer` twice
- Control bar height must not grow significantly (~40px total for the stacked pair vs current 32px single)
- No labels; color difference alone distinguishes the two channels
- Backend already emits `{ you: number, them: number }` from the `audio-level` Tauri event — no backend changes required

## Changes

### 1. `src/theme.ts`

Add `themLight: "#dba86e"` alongside `them: "#c98b4f"`, mirroring the existing `accent` / `accentLight` pattern. This lighter tint is used as the middle gradient stop in `WaveformVisualizer` for the "them" waveform.

### 2. `WaveformVisualizer.tsx`

Add optional `color?: string` and `colorLight?: string` props. Both default to `colors.accent` and `colors.accentLight` respectively, preserving existing behavior for the "you" waveform.

- Change canvas `height` from `32` to `18`. **This applies to both the "you" and "them" waveform instances — it is intentional.** The reduced height is what allows the stacked pair to remain within the ~40px control bar height budget (18 + 4px gap + 18 = 40px). The amplitude range is halved but the visualization remains readable at this size.
- Replace hardcoded `colors.accent` / `colors.accentLight` gradient stops with `color` and `colorLight` props.
- Replace hardcoded `${colors.accent}20` fill with `${color}20` so the fill also uses the passed-in color.
- The flat-line stroke (`colors.border`) is unchanged by the `color` prop — it remains neutral for both waveform instances.
- Props: `color?: string` and `colorLight?: string`, with defaults in the destructuring signature (`color = colors.accent`, `colorLight = colors.accentLight`).

### 3. `App.tsx`

Add `audioLevelThem` state (`number`, default `0`). In the existing `audio-level` listener (already typed as `listen<{ you: number; them: number }>`), set `audioLevelThem` from `e.payload.them` alongside the existing `setAudioLevel(e.payload.you)`. Pass `audioLevelThem` down to `<ControlBar>`.

### 4. `ControlBar.tsx`

Add `audioLevelThem?: number` to `Props` (default `0`). In the `isRunning` section, replace the single `<WaveformVisualizer>` with two stacked in a column flex container:

```tsx
<div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
  <WaveformVisualizer level={audioLevel} isActive={isRunning} />
  <WaveformVisualizer
    level={audioLevelThem}
    isActive={isRunning}
    color={colors.them}
    colorLight={colors.themLight}
  />
</div>
```

The outer control bar row uses `alignItems: "center"`, which vertically centers all flex children. The stacked waveform div will be 40px tall. Adjacent elements (the timer span at ~20px, the LIVE badge at ~24px) are shorter, so they will center against the 40px waveform column. This is acceptable — the timer and badge sit visually mid-height relative to the waveform pair.

## Visual Result

When recording, the control bar shows:

```
[ timer ] [ ~~~you waveform (accent/teal)~~~ ]   [ LIVE ]
           [ ~~~them waveform (amber)~~~~~~~ ]
```

Both waveforms animate independently based on their respective audio levels. When either channel is silent (level < 0.02), it renders as a flat line.

## Known Limitations

- When recording but system audio capture has no active source (device not configured or no audio playing), `isActive` is `true` but `level` is `0`, so the "them" waveform shows a flat line. This is correct behavior — the flat line is the right visual signal for silence.

## Out of Scope

- Labels ("You" / "Them") — not needed; color is sufficient
- Backend changes — already done
- macOS/Windows audio capture logic — unchanged
