# Spotify-Style Audio Bars — Design Spec

**Date:** 2026-03-25
**Status:** Approved

## Problem

The current `WaveformVisualizer` draws a smooth sine wave with noise. The user wants a more recognizable audio activity indicator — the classic Spotify-style animated equalizer bars: a small cluster of vertical bars that bounce at slightly different speeds proportional to the audio level.

## Goal

Replace the sine wave drawing logic in `WaveformVisualizer` with Spotify-style animated vertical bars. Both waveform instances (you/them) get this treatment. No other files change.

## Constraints

- Only `WaveformVisualizer.tsx` changes — component API, canvas size (140×18px), and usage in `ControlBar` are unchanged
- `color` and `colorLight` props are preserved for API compatibility; `colorLight` becomes unused
- Silence state: 3 short static stubs (not a flat line)
- No new files, no new components

## Design

### Visual Layout

3 vertical bars centered in the 140×18px canvas. Bars grow upward from the bottom.

- Bar width: 6px
- Gap between bars: 4px
- Total cluster width: 26px (centered in 140px, offset = 57px)
- Max bar height: 14px (2px margin top and bottom)
- Min bar height (silence): 3px

### Animation

Replace the `setInterval` + `dataArray` + `useState` approach with a single `requestAnimationFrame` loop driven by `performance.now()`.

Each bar has an independent speed multiplier and phase offset:

| Bar | Speed | Phase   |
|-----|-------|---------|
| 0   | 1.0   | 0       |
| 1   | 1.4   | π/3     |
| 2   | 0.8   | 2π/3    |

Height formula per bar:
```
height = normalizedLevel × maxHeight × (0.6 + 0.4 × sin(t × speed + phase))
```

Where `t = performance.now() / 300` (controls overall bounce tempo).

This produces natural independent bouncing that scales to zero when audio level is zero.

### Silence State

When `!isActive` or `normalizedLevel < 0.02`:
- Draw 3 static stubs, 3px tall, centered at the bottom of the canvas
- Fill color: `colors.border`
- No animation loop — cancel `requestAnimationFrame` and draw once

### Colors

Each bar is filled with a solid `color` prop value (default `colors.accent` for "you", `colors.them` for "them"). No per-bar gradient. The `colorLight` prop is retained in the interface but unused in rendering.

### Removing Old Code

- Remove `dataArray` state (`useState<Float32Array>`)
- Remove the `generateData` interval (`setInterval` in the first `useEffect`)
- Remove the second `useEffect` that depended on `dataArray`
- Replace with a single `useEffect` that runs a `requestAnimationFrame` loop

## Changes

### `WaveformVisualizer.tsx`

- Remove `useState` import (no longer needed)
- Remove `dataArray` state and `generateData` interval
- Remove the two-effect pattern; replace with one `useEffect`
- New effect: starts a `rAF` loop when `isActive && normalizedLevel >= 0.02`, draws 3 bouncing bars using `performance.now()`; cancels loop and draws static stubs otherwise
- Props interface unchanged

## Out of Scope

- Changing canvas size
- Changing the number of bars (fixed at 3)
- Configurable bar count or speed
- Modifying `ControlBar`, `App.tsx`, or `theme.ts`
