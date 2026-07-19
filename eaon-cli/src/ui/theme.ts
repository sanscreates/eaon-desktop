// Shared palette. Accent orange matches Eaon's brand mark across the macOS
// app and the Tauri build; the rest is a plain, readable dark-terminal set.

export const theme = {
  accent: "#F17455",
  assistant: "#ECECEC",
  user: "#8FD6FF",
  reasoning: "#8E8E9C",
  toolName: "#64D2FF",
  success: "#3FB950",
  error: "#FF6467",
  warning: "#E3B341",
  diffAdded: "#3FB950",
  diffRemoved: "#FF6467",
  muted: "#6E6E7A",
  border: "#3A3A42",
} as const;

export const PERMISSION_COLORS = {
  sandboxed: "#C7A6FF",
  auto: "#E3B341",
} as const;

export const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] as const;

export const MODE_LABEL: Record<string, string> = {
  chat: "Chat",
  agent: "Agent",
  claw: "Agent", // old sessions saved as claw resume into Agent
};
