/**
 * OpenCassava Design System
 * Centralized theme configuration for consistent styling across the app
 */

export const theme = {
  // Color palette - Clean, warm, professional
  colors: {
    // Backgrounds
    background: "#faf8f5",      // Warm off-white (was #111111)
    surface: "#ffffff",         // Pure white cards (was #1a1a1a)
    surfaceElevated: "#f5f3f0", // Slightly elevated surfaces (was #222222)

    // Borders
    border: "#e8e4df",          // Warm light border (was #333333)
    borderFocus: "#d0c8c0",     // Focused border state

    // Text
    text: "#1a1816",            // Near-black with warmth (was #eeeeee)
    textSecondary: "#6b6560",   // Gray with warmth (was #888888)
    textMuted: "#9a948e",       // Lighter gray (was #666666)
    textInverse: "#ffffff",     // White text for dark backgrounds

    // Accent - Warmer teal
    accent: "#2d8a87",         // Primary brand color (was #2b7a78)
    accentLight: "#3aa8a4",     // Lighter accent
    accentMuted: "#e8f4f4",     // Very light accent background

    // Semantic colors - softened
    success: "#2d9d5c",         // Soft green (was #27ae60)
    error: "#c45a4f",           // Warm red (was #c0392b)
    warning: "#d4912a",         // Warm amber (was #f39c12)
    info: "#4a90d4",            // Soft blue

    // Speaker colors - refined
    you: "#4a7fb5",             // Muted blue (was #5b8cbf)
    them: "#c98b4f",            // Warm amber (was #d2994d)

    // Overlay specific (glassmorphism)
    overlay: {
      background: "rgba(255, 255, 255, 0.92)",
      border: "rgba(200, 190, 180, 0.4)",
      text: "#1a1816",
      accent: "#2d8a87",
      shadow: "0 8px 32px rgba(0, 0, 0, 0.12)",
    },
  },

  // Typography
  typography: {
    xs: 10,
    sm: 11,
    base: 12,
    md: 13,
    lg: 14,
    xl: 15,
    "2xl": 16,
    "3xl": 18,
  },

  // Spacing
  spacing: {
    0: 0,
    1: 4,
    2: 8,
    3: 12,
    4: 16,
    5: 20,
    6: 24,
    8: 32,
    10: 40,
  },

  // Border radius
  radius: {
    sm: 4,
    md: 6,
    lg: 8,
    xl: 12,
    full: 9999,
  },

  // Shadows
  shadows: {
    sm: "0 1px 2px rgba(0, 0, 0, 0.04)",
    md: "0 2px 8px rgba(0, 0, 0, 0.06)",
    lg: "0 4px 16px rgba(0, 0, 0, 0.08)",
    xl: "0 8px 32px rgba(0, 0, 0, 0.12)",
  },
} as const;

// Export individual values for convenience
export const { colors, typography, spacing, radius, shadows } = theme;

// Common CSS property objects for reuse
export const styles = {
  // Layout containers
  page: {
    height: "100vh",
    display: "flex",
    flexDirection: "column" as const,
    background: colors.background,
    color: colors.text,
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
  },

  center: {
    height: "100vh",
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    background: colors.background,
  },

  // Card styles
  card: {
    background: colors.surface,
    border: `1px solid ${colors.border}`,
    borderRadius: radius.lg,
    padding: `${spacing[4]}px`,
  },

  // Button styles
  button: {
    padding: `${spacing[2]}px ${spacing[3]}px`,
    background: colors.accent,
    color: colors.textInverse,
    border: "none",
    borderRadius: radius.md,
    fontSize: typography.base,
    cursor: "pointer",
    fontWeight: 500,
    transition: "background 0.2s, transform 0.1s",
  },

  buttonSecondary: {
    padding: `${spacing[2]}px ${spacing[3]}px`,
    background: colors.surfaceElevated,
    color: colors.textSecondary,
    border: `1px solid ${colors.border}`,
    borderRadius: radius.md,
    fontSize: typography.base,
    cursor: "pointer",
    transition: "background 0.2s",
  },

  buttonDanger: {
    padding: `${spacing[2]}px ${spacing[3]}px`,
    background: "transparent",
    color: colors.error,
    border: `1px solid ${colors.border}`,
    borderRadius: radius.md,
    fontSize: typography.base,
    cursor: "pointer",
  },

  // Input styles
  input: {
    width: "100%",
    padding: `${spacing[2]}px`,
    background: colors.surface,
    color: colors.text,
    border: `1px solid ${colors.border}`,
    borderRadius: radius.sm,
    fontSize: typography.md,
    boxSizing: "border-box" as const,
    fontFamily: "inherit",
  },

  select: {
    padding: `${spacing[2]}px`,
    background: colors.surface,
    color: colors.text,
    border: `1px solid ${colors.border}`,
    borderRadius: radius.sm,
    fontSize: typography.md,
    cursor: "pointer",
  },

  // Status badges
  badge: (type: "success" | "warning" | "error" | "info" | "accent") => ({
    display: "inline-flex" as const,
    alignItems: "center" as const,
    gap: `${spacing[1]}px`,
    padding: `${spacing[1]}px ${spacing[2]}px`,
    background:
      type === "success"
        ? `${colors.success}15`
        : type === "warning"
        ? `${colors.warning}15`
        : type === "error"
        ? `${colors.error}15`
        : type === "accent"
        ? `${colors.accent}15`
        : `${colors.info}15`,
    color:
      type === "success"
        ? colors.success
        : type === "warning"
        ? colors.warning
        : type === "error"
        ? colors.error
        : type === "accent"
        ? colors.accent
        : colors.info,
    borderRadius: radius.md,
    fontSize: typography.sm,
    fontWeight: 500,
  }),

  // Tab styles
  tab: (isActive: boolean) => ({
    padding: `${spacing[2]}px ${spacing[3]}px`,
    background: "transparent",
    border: "none",
    borderBottom: isActive ? `2px solid ${colors.accent}` : "2px solid transparent",
    color: isActive ? colors.accent : colors.textSecondary,
    fontSize: typography.base,
    fontWeight: isActive ? 600 : 400,
    cursor: "pointer",
    transition: "all 0.2s",
  }),

  // Scrollable area
  scrollable: {
    flex: 1,
    overflowY: "auto" as const,
  },

  // Empty state
  emptyState: {
    flex: 1,
    display: "flex" as const,
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    color: colors.textMuted,
    padding: `${spacing[6]}px`,
    textAlign: "center" as const,
  },

  // Icon container
  iconContainer: {
    width: 48,
    height: 48,
    borderRadius: radius.lg,
    background: `${colors.accent}12`,
    display: "flex" as const,
    alignItems: "center",
    justifyContent: "center",
    fontSize: 24,
    marginBottom: `${spacing[3]}px`,
  },
} as const;
