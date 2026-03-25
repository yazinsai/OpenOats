import { useEffect, useRef } from "react";
import { colors } from "../theme";

interface Props {
  level: number; // 0-1
  isActive: boolean;
  color?: string;
  colorLight?: string;
}

const BAR_COUNT = 12;
const BAR_WIDTH = 6;
const BAR_GAP = 4;
const BAR_STRIDE = BAR_WIDTH + BAR_GAP;
const CLUSTER_WIDTH = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP; // 116px
const MAX_BAR_HEIGHT = 18; // full canvas height
const MIN_ACTIVE_BAR_HEIGHT = 2;
const SILENCE_BAR_HEIGHT = 3;
const CORNER_RADIUS = 2;
// Wave speed scales with audio level — stationary at silence, fast at loud
const SPATIAL_FREQ = (2 * Math.PI) / BAR_COUNT;
const BASE_TEMPORAL_FREQ = 0.004; // radians per ms at full volume

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
      // Wave speed proportional to audio level: silent = barely moves, loud = fast
      const t = performance.now() * BASE_TEMPORAL_FREQ * visualLevel;
      for (let i = 0; i < BAR_COUNT; i++) {
        const wave = 0.5 + 0.5 * Math.sin(i * SPATIAL_FREQ - t);
        const barHeight = Math.max(
          MIN_ACTIVE_BAR_HEIGHT,
          visualLevel * MAX_BAR_HEIGHT * wave
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
