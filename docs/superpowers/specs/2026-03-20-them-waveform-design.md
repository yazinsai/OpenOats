# Them Waveform Visualizer — Design Spec

**Date:** 2026-03-20
**Status:** Approved

## Problem

The control bar shows a waveform for the microphone ("you") while recording, but the "them" (system/speaker) audio level is already captured and emitted by the backend — it's simply never visualized. Users have no feedback that speaker audio is being picked up.

## Goal

Add a second waveform for the "them" audio, stacked vertically below the existing "you" waveform, using a distinct color.

## Constraints

- No new components needed — reuse `WaveformVisualizer` twice
- Control bar height must not grow significantly (~40px total for the stacked pair, same as the current 32px single)
- No labels; color difference alone distinguishes the two channels
- Backend already emits `{ you: number, them: number }` from the `audio-level` Tauri event — no backend changes required

## Changes

### 1. `WaveformVisualizer.tsx`

Add optional `color?: string` prop. Defaults to `colors.accent` (preserving existing behavior). Used for the gradient stroke and fill in the draw loop.

- Change canvas `height` default from `32` to `18`
- Replace hardcoded `colors.accent` / `colors.accentLight` references with the `color` prop value (use `color` for stops 0 and 1, and a lighter variant or same color at 50%)

### 2. `App.tsx`

Add `audioLevelThem` state (`number`, default `0`). In the existing `audio-level` listener, set it from `e.payload.them`. Pass `audioLevelThem` to `<ControlBar>`.

### 3. `ControlBar.tsx`

Add `audioLevelThem?: number` to `Props` (default `0`). In the `isRunning` section, replace the single `<WaveformVisualizer>` with:

```tsx
<div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
  <WaveformVisualizer level={audioLevel} isActive={isRunning} />
  <WaveformVisualizer level={audioLevelThem} isActive={isRunning} color={colors.them} />
</div>
```

## Visual Result

When recording, the control bar shows:

```
[ timer ] [ ~~~you waveform (accent color)~~~ ]   [ LIVE ]
           [ ~~~them waveform (them color)~~~  ]
```

Both waveforms animate independently based on their respective audio levels. When either channel is silent (level < 0.02), it renders as a flat line.

## Out of Scope

- Labels ("You" / "Them") — not needed; color is sufficient
- Backend changes — already done
- macOS/Windows audio capture logic — unchanged
