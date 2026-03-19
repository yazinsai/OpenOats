import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";

interface SuggestionPayload {
  id: string;
  text: string;
}

export function OverlayApp() {
  const [suggestion, setSuggestion] = useState<SuggestionPayload | null>(null);

  useEffect(() => {
    const root = document.getElementById("root");
    const previousBodyBackground = document.body.style.background;
    const previousBodyOverflow = document.body.style.overflow;
    const previousRootWidth = root?.style.width ?? "";
    const previousRootMaxWidth = root?.style.maxWidth ?? "";
    const previousRootMargin = root?.style.margin ?? "";
    const previousRootBorder = root?.style.border ?? "";
    const previousRootMinHeight = root?.style.minHeight ?? "";
    const previousRootDisplay = root?.style.display ?? "";

    document.body.style.background = "transparent";
    document.body.style.overflow = "hidden";

    if (root) {
      root.style.width = "100vw";
      root.style.maxWidth = "100vw";
      root.style.margin = "0";
      root.style.border = "none";
      root.style.minHeight = "100vh";
      root.style.display = "block";
    }

    const unlisten = listen<SuggestionPayload>("suggestion", (e) => {
      setSuggestion(e.payload);
    });

    return () => {
      document.body.style.background = previousBodyBackground;
      document.body.style.overflow = previousBodyOverflow;

      if (root) {
        root.style.width = previousRootWidth;
        root.style.maxWidth = previousRootMaxWidth;
        root.style.margin = previousRootMargin;
        root.style.border = previousRootBorder;
        root.style.minHeight = previousRootMinHeight;
        root.style.display = previousRootDisplay;
      }

      unlisten.then((f) => f());
    };
  }, []);

  if (!suggestion) {
    return (
      <div style={containerStyle}>
        <span style={{ color: "#555", fontSize: 13 }}>Waiting for suggestions…</span>
      </div>
    );
  }

  const dismiss = () => {
    setSuggestion(null);
    invoke("hide_overlay").catch(() => {});
  };

  return (
    <div style={containerStyle}>
      <div style={cardStyle}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
          <p style={{ margin: 0, fontSize: 13, color: "#eee", lineHeight: 1.5, flex: 1 }}>
            {suggestion.text}
          </p>
          <button onClick={dismiss} style={closeBtn} title="Dismiss">✕</button>
        </div>
      </div>
    </div>
  );
}

const containerStyle: React.CSSProperties = {
  width: "100vw",
  height: "100vh",
  display: "flex",
  alignItems: "flex-start",
  justifyContent: "center",
  background: "transparent",
  padding: "18px 20px",
  boxSizing: "border-box",
  overflow: "hidden",
  pointerEvents: "none",
};

const cardStyle: React.CSSProperties = {
  background: "rgba(15, 18, 24, 0.72)",
  border: "1px solid rgba(210, 153, 77, 0.35)",
  borderRadius: 16,
  padding: "12px 14px",
  width: "min(560px, calc(100vw - 40px))",
  maxHeight: "calc(100vh - 36px)",
  overflow: "hidden",
  backdropFilter: "blur(18px)",
  boxShadow: "0 16px 40px rgba(0,0,0,0.28)",
  pointerEvents: "auto",
};

const closeBtn: React.CSSProperties = {
  background: "transparent",
  border: "none",
  color: "rgba(255,255,255,0.58)",
  cursor: "pointer",
  fontSize: 14,
  lineHeight: 1,
  padding: 0,
  flexShrink: 0,
};
