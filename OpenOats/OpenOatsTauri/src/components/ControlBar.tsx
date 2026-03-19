import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";

// Design system
const colors = {
  background: "#111111",
  surface: "#1a1a1a",
  surfaceElevated: "#222222",
  border: "#333333",
  text: "#eeeeee",
  textSecondary: "#888888",
  accent: "#2b7a78",
  success: "#27ae60",
  error: "#c0392b",
  warning: "#f39c12",
  you: "#5b8cbf",
  them: "#d2994d",
};

const typography = {
  xs: 10,
  sm: 11,
  base: 12,
  md: 13,
  lg: 14,
};

const spacing = {
  1: 4,
  2: 8,
  3: 12,
  4: 16,
};

interface Props {
  isRunning: boolean;
  onStart: () => void;
  onStop: () => void;
  disabled?: boolean;
  modelName?: string;
  whisperModel?: string;
  transcriptionLocale?: string;
  kbConnected?: boolean;
  kbFileCount?: number;
  isLocalMode?: boolean;
}

// Audio level visualizer component
function AudioLevelVisualizer({ level }: { level: number }) {
  const bars = 5;
  return (
    <div style={{ display: "flex", gap: 2, alignItems: "center", height: 14 }}>
      {Array.from({ length: bars }).map((_, i) => {
        const threshold = i / bars;
        const isActive = level > threshold;
        return (
          <div
            key={i}
            style={{
              width: 3,
              height: 4 + i * 2,
              borderRadius: 1,
              background: isActive ? `${colors.success}cc` : `${colors.textSecondary}20`,
              transition: "background 0.08s ease-out",
            }}
          />
        );
      })}
    </div>
  );
}

// Format seconds to MM:SS or HH:MM:SS
function formatDuration(seconds: number): string {
  const hrs = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  
  if (hrs > 0) {
    return `${hrs}:${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
  }
  return `${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
}

export function ControlBar({
  isRunning,
  onStart,
  onStop,
  disabled,
  modelName = "Unknown",
  whisperModel = "base-en",
  transcriptionLocale = "en-US",
  kbConnected = false,
  kbFileCount = 0,
  isLocalMode = true,
}: Props) {
  const [devices, setDevices] = useState<string[]>([]);
  const [selectedDevice, setSelectedDevice] = useState<string>("default");
  const [audioLevel, setAudioLevel] = useState(0);
  const [duration, setDuration] = useState(0);
  const durationRef = useRef(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    invoke<string[]>("list_mic_devices").then((d) => {
      setDevices(d);
    });
  }, []);

  // Handle recording duration
  useEffect(() => {
    if (isRunning) {
      durationRef.current = 0;
      setDuration(0);
      intervalRef.current = setInterval(() => {
        durationRef.current += 1;
        setDuration(durationRef.current);
      }, 1000);
    } else {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
      setDuration(0);
    }

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [isRunning]);

  useEffect(() => {
    let active = true;
    let unlistenFn: (() => void) | null = null;

    if (isRunning) {
      import("@tauri-apps/api/event").then(({ listen }) => {
        listen<{ you: number; them: number }>("audio-level", (e) => {
          if (active) setAudioLevel(e.payload.you);
        }).then((f) => {
          if (active) {
            unlistenFn = f;
          } else {
            f(); // already cleaned up, immediately unlisten
          }
        });
      });
    } else {
      setAudioLevel(0);
    }

    return () => {
      active = false;
      unlistenFn?.();
    };
  }, [isRunning]);

  const handleDeviceChange = async (device: string) => {
    setSelectedDevice(device);
    try {
      const settings = await invoke<any>("get_settings");
      await invoke("save_settings", {
        newSettings: { ...settings, inputDeviceName: device === "default" ? null : device },
      });
    } catch (e) {
      console.error("Failed to save device:", e);
    }
  };

  const buttonStyle: React.CSSProperties = {
    display: "flex",
    alignItems: "center",
    gap: spacing[2],
    padding: `${spacing[2]}px ${spacing[3]}px`,
    background: isRunning ? `${colors.error}20` : colors.success,
    color: isRunning ? colors.error : "#fff",
    border: isRunning ? `1px solid ${colors.error}50` : "none",
    borderRadius: 20,
    fontSize: typography.md,
    fontWeight: 600,
    cursor: disabled ? "not-allowed" : "pointer",
    opacity: disabled ? 0.5 : 1,
    transition: "all 0.2s",
  };

  const statusBadgeStyle = (color: string): React.CSSProperties => ({
    display: "inline-flex",
    alignItems: "center",
    gap: spacing[1],
    padding: `${spacing[1]}px ${spacing[2]}px`,
    background: `${color}15`,
    color: color,
    borderRadius: 12,
    fontSize: typography.sm,
    fontWeight: 500,
  });

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: spacing[3],
        padding: `${spacing[2]}px ${spacing[4]}px`,
        background: colors.surface,
        borderBottom: `1px solid ${colors.border}`,
      }}
    >
      {/* Microphone Selector */}
      <select
        value={selectedDevice}
        onChange={(e) => handleDeviceChange(e.target.value)}
        disabled={isRunning}
        style={{
          padding: `${spacing[2]}px`,
          background: colors.background,
          color: colors.text,
          border: `1px solid ${colors.border}`,
          borderRadius: 4,
          fontSize: typography.base,
          minWidth: 140,
          cursor: isRunning ? "not-allowed" : "pointer",
          opacity: isRunning ? 0.6 : 1,
        }}
      >
        <option value="default">🎤 System Default</option>
        {devices.map((d) => (
          <option key={d} value={d}>
            {d}
          </option>
        ))}
        {devices.length === 0 && (
          <option value="" disabled>
            No microphones found
          </option>
        )}
      </select>

      {/* Main Control Button */}
      <button onClick={isRunning ? onStop : onStart} disabled={disabled} style={buttonStyle}>
        {isRunning ? (
          <>
            {/* Live indicator with pulse */}
            <span
              style={{
                display: "inline-block",
                width: 8,
                height: 8,
                borderRadius: "50%",
                background: colors.error,
                animation: "pulse 1.5s ease-in-out infinite",
              }}
            />
            <span>Stop</span>
          </>
        ) : (
          <>
            <span style={{ fontSize: 10 }}>⏺</span>
            <span>Record</span>
          </>
        )}
      </button>

      {/* Recording Status Section */}
      {isRunning && (
        <div style={{ display: "flex", alignItems: "center", gap: spacing[3] }}>
          {/* Duration Timer */}
          <span
            style={{
              fontSize: typography.md,
              fontWeight: 600,
              color: colors.text,
              fontFamily: "SF Mono, Monaco, monospace",
              letterSpacing: "0.5px",
            }}
          >
            {formatDuration(duration)}
          </span>

          {/* Audio Level */}
          <AudioLevelVisualizer level={audioLevel} />

          {/* Live Badge */}
          <span style={statusBadgeStyle(colors.success)}>
            <span style={{ fontSize: 6 }}>●</span>
            <span>LIVE</span>
          </span>
        </div>
      )}

      <div style={{ flex: 1 }} />

      {/* Status Indicators */}
      <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
        {/* KB Status */}
        {kbConnected ? (
          <span style={statusBadgeStyle(colors.accent)}>
            <span>⚡</span>
            <span>KB {kbFileCount > 0 ? kbFileCount : ""}</span>
          </span>
        ) : (
          <span
            style={{
              ...statusBadgeStyle(colors.textSecondary),
              opacity: 0.6,
            }}
          >
            <span>📁</span>
            <span>No KB</span>
          </span>
        )}

        {/* Mode Indicator */}
        <span
          style={statusBadgeStyle(isLocalMode ? colors.success : colors.you)}
          title={isLocalMode ? "Local mode - no data leaves your device" : "Cloud mode - using external APIs"}
        >
          <span style={{ fontSize: 6 }}>●</span>
          <span>{isLocalMode ? "Local" : "Cloud"}</span>
        </span>

        {/* Model Badge */}
        <span
          style={{
            padding: `${spacing[1]}px ${spacing[2]}px`,
            background: colors.background,
            color: colors.textSecondary,
            borderRadius: 12,
            fontSize: typography.xs,
            fontWeight: 500,
            fontFamily: "SF Mono, Monaco, monospace",
          }}
          title="Active AI model"
        >
          {modelName.length > 20 ? modelName.split("/").pop() : modelName}
        </span>

        <span
          style={{
            padding: `${spacing[1]}px ${spacing[2]}px`,
            background: colors.background,
            color: colors.them,
            borderRadius: 12,
            fontSize: typography.xs,
            fontWeight: 500,
            fontFamily: "SF Mono, Monaco, monospace",
          }}
          title="Active Whisper transcription model"
        >
          {whisperModel} · {transcriptionLocale || "auto"}
        </span>
      </div>

      {/* Add pulse animation */}
      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; transform: scale(1); }
          50% { opacity: 0.6; transform: scale(0.9); }
        }
      `}</style>
    </div>
  );
}
