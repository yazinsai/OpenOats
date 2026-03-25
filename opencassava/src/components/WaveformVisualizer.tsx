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
