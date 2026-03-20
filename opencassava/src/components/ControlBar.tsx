import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { WaveformVisualizer } from "./WaveformVisualizer";
import { colors, typography, spacing } from "../theme";

interface Props {
  isRunning: boolean;
  onStart: () => void;
  onStop: () => void;
  disabled?: boolean;
  kbConnected?: boolean;
  kbFileCount?: number;
  isSuggestionAnalyzing?: boolean;
  lastSuggestionCheckAt?: string | null;
  lastSuggestionCheckSurfaced?: boolean | null;
  audioLevel?: number;
}

function formatRelativeTime(iso: string | null | undefined): string {
  if (!iso) return "Waiting";
  const deltaSeconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (deltaSeconds < 5) return "Just now";
  if (deltaSeconds < 60) return `${deltaSeconds}s ago`;
  const minutes = Math.floor(deltaSeconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}

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
  kbConnected = false,
  kbFileCount = 0,
  isSuggestionAnalyzing = false,
  lastSuggestionCheckAt = null,
  lastSuggestionCheckSurfaced = null,
  audioLevel = 0,
}: Props) {
  const [devices, setDevices] = useState<string[]>([]);
  const [selectedDevice, setSelectedDevice] = useState<string>("default");
  const [sysDevices, setSysDevices] = useState<string[]>([]);
  const [selectedSysDevice, setSelectedSysDevice] = useState<string>("default");
  const [duration, setDuration] = useState(0);
  const durationRef = useRef(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    Promise.all([
      invoke<string[]>("list_mic_devices"),
      invoke<string[]>("list_sys_audio_devices"),
      invoke<any>("get_settings"),
    ]).then(([mics, sysDevs, s]) => {
      setDevices(mics);
      setSysDevices(sysDevs);
      if (s.inputDeviceName) setSelectedDevice(s.inputDeviceName);
      if (s.systemAudioDeviceName) setSelectedSysDevice(s.systemAudioDeviceName);
    });
  }, []);

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

  const handleSysDeviceChange = async (device: string) => {
    setSelectedSysDevice(device);
    try {
      const settings = await invoke<any>("get_settings");
      await invoke("save_settings", {
        newSettings: { ...settings, systemAudioDeviceName: device === "default" ? null : device },
      });
    } catch (e) {
      console.error("Failed to save sys audio device:", e);
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
    color,
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
        <option value="default">Mic Default</option>
        {devices.map((d) => (
          <option key={d} value={d}>
            {d}
          </option>
        ))}
        {devices.length === 0 && <option value="" disabled>No microphones found</option>}
      </select>

      <select
        value={selectedSysDevice}
        onChange={(e) => handleSysDeviceChange(e.target.value)}
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
        <option value="default">System Audio Default</option>
        {sysDevices.map((d) => (
          <option key={d} value={d}>
            {d}
          </option>
        ))}
      </select>

      <button onClick={isRunning ? onStop : onStart} disabled={disabled} style={buttonStyle}>
        {isRunning ? (
          <>
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
            <span style={{ fontSize: 10 }}>Rec</span>
            <span>Record</span>
          </>
        )}
      </button>

      {isRunning && (
        <div style={{ display: "flex", alignItems: "center", gap: spacing[3] }}>
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

          <WaveformVisualizer level={audioLevel} isActive={isRunning} />

          <span style={statusBadgeStyle(colors.success)}>
            <span style={{ fontSize: 6 }}>o</span>
            <span>LIVE</span>
          </span>
        </div>
      )}

      <div style={{ flex: 1 }} />

      <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
        {kbConnected ? (
          <span style={statusBadgeStyle(colors.accent)}>
            <span>KB</span>
            <span>{kbFileCount > 0 ? kbFileCount : ""}</span>
          </span>
        ) : (
          <span style={{ ...statusBadgeStyle(colors.textSecondary), opacity: 0.6 }}>
            <span>No KB</span>
          </span>
        )}

        {isRunning && (
          <span
            style={statusBadgeStyle(
              isSuggestionAnalyzing
                ? colors.them
                : lastSuggestionCheckSurfaced
                  ? colors.success
                  : colors.textSecondary,
            )}
          >
            <span style={{ fontSize: 6 }}>{isSuggestionAnalyzing ? "o" : "O"}</span>
            <span>
              {isSuggestionAnalyzing ? "Analyzing" : `Suggestions ${formatRelativeTime(lastSuggestionCheckAt)}`}
            </span>
          </span>
        )}
      </div>

      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; transform: scale(1); }
          50% { opacity: 0.6; transform: scale(0.9); }
        }
      `}</style>
    </div>
  );
}
