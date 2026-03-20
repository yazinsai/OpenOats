import { useEffect, useCallback } from "react";

interface ShortcutHandlers {
  onStartStop?: () => void;
  onDismissOverlay?: () => void;
  onFocusSearch?: () => void;
  onExportTranscript?: () => void;
  onToggleSidebar?: () => void;
}

export function useKeyboardShortcuts(handlers: ShortcutHandlers) {
  const handleKeyDown = useCallback(
    (event: KeyboardEvent) => {
      const isMac = navigator.platform.toUpperCase().indexOf("MAC") >= 0;
      const modKey = isMac ? event.metaKey : event.ctrlKey;

      // Cmd/Ctrl + Shift + S = Start/Stop
      if (modKey && event.shiftKey && event.key.toLowerCase() === "s") {
        event.preventDefault();
        handlers.onStartStop?.();
      }

      // Cmd/Ctrl + F = Focus search
      if (modKey && event.key.toLowerCase() === "f") {
        event.preventDefault();
        handlers.onFocusSearch?.();
      }

      // Cmd/Ctrl + E = Export
      if (modKey && event.key.toLowerCase() === "e") {
        event.preventDefault();
        handlers.onExportTranscript?.();
      }

      // Cmd/Ctrl + B = Toggle sidebar
      if (modKey && event.key.toLowerCase() === "b") {
        event.preventDefault();
        handlers.onToggleSidebar?.();
      }

      // Escape = Dismiss
      if (event.key === "Escape") {
        handlers.onDismissOverlay?.();
      }
    },
    [handlers]
  );

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [handleKeyDown]);
}

export function useOverlayKeyboardShortcuts(onDismiss: () => void) {
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onDismiss();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onDismiss]);
}
