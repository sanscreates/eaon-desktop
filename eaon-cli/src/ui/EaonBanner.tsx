// The welcome banner — modeled closely on Claude Code's own launch screen
// per the reference screenshots: version embedded in the top border, a
// personalized greeting, a centered logo mark, centered model/path info,
// and — on a wide enough terminal — a second column beside the box for
// "Tips for getting started" + "Recent sessions" (Claude Code's own
// "Recent activity"). Narrower terminals fall back to a single stacked
// column instead of clipping or wrapping badly.
//
// The logo is a hand-built 5-row block font spelling "EAON", not a
// screenshot-traced mascot — there's no way to visually proof a bespoke
// pixel-art creature here, so this sticks to a typographic mark that's easy
// to get unambiguously right (see the width-invariant checks run before
// shipping this, plus a real pseudo-TTY capture — see PR notes).

import React from "react";
import os from "node:os";
import { Box, Text, useStdout } from "ink";
import { theme, MODE_LABEL } from "./theme.js";
import type { Quote } from "./quotes.js";
import type { EaonMode } from "../types.js";
import type { SessionSummary } from "../session/store.js";

const GLYPHS: Record<string, string[]> = {
  E: ["█████", "█    ", "████ ", "█    ", "█████"],
  A: [" ███ ", "█   █", "█████", "█   █", "█   █"],
  O: [" ███ ", "█   █", "█   █", "█   █", " ███ "],
  N: ["█   █", "██  █", "█ █ █", "█  ██", "█   █"],
};

function wordmarkRows(word: string): string[] {
  const letters = word.split("").map((ch) => GLYPHS[ch] ?? ["     ", "     ", "     ", "     ", "     "]);
  const rows: string[] = [];
  for (let r = 0; r < 5; r++) rows.push(letters.map((letter) => letter[r]).join(" "));
  return rows;
}

const EAON_WORDMARK = wordmarkRows("EAON");

function padCenter(text: string, width: number): string {
  if (text.length >= width) return text.slice(0, width);
  const totalPad = width - text.length;
  const left = Math.floor(totalPad / 2);
  return " ".repeat(left) + text + " ".repeat(totalPad - left);
}

function wrapText(text: string, width: number): string[] {
  const words = text.split(" ");
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const candidate = current.length === 0 ? word : `${current} ${word}`;
    if (candidate.length > width && current.length > 0) {
      lines.push(current);
      current = word;
    } else {
      current = candidate;
    }
  }
  if (current.length > 0) lines.push(current);
  return lines.length > 0 ? lines : [""];
}

function truncateFromLeft(text: string, width: number): string {
  if (text.length <= width) return text;
  return "…" + text.slice(text.length - (width - 1));
}

/** The real OS login name — not fabricated, and not worth the complexity
 * of shelling out per-platform for a GECOS/display name (`os.userInfo()`
 * exposes only the login handle on every platform, no full-name field). */
function greetingName(): string {
  try {
    return os.userInfo().username || "there";
  } catch {
    return "there";
  }
}

interface Row {
  text: string;
  color: string;
  bold?: boolean;
  italic?: boolean;
}

export interface EaonBannerProps {
  version: string;
  quote: Quote;
  mode: EaonMode;
  modelLabel: string;
  projectRoot: string;
  recentSessions: SessionSummary[];
}

/** Pure layout builder — separated from the React component so the exact
 * row/width math (and the side-by-side vs. stacked decision) can be
 * unit-tested without an Ink render. */
export function buildBannerLayout(props: EaonBannerProps, terminalColumns: number) {
  const innerWidth = Math.min(56, Math.max(40, terminalColumns - 8));
  const boxTotalWidth = innerWidth + 2;

  const titleSegment = `─ Eaon v${props.version} `;
  const dashCount = Math.max(1, innerWidth - titleSegment.length);
  const topBorder = "╭" + titleSegment + "─".repeat(dashCount) + "╮";
  const bottomBorder = "╰" + "─".repeat(innerWidth) + "╯";

  const quoteWidth = innerWidth - 4;
  const quoteLines = wrapText(`“${props.quote.text}”`, quoteWidth);
  const attribution = `— ${props.quote.author}`;
  const footerText = `${MODE_LABEL[props.mode]} · ${props.modelLabel}`;
  const footerLines = wrapText(footerText, innerWidth - 2);
  const pathLine = truncateFromLeft(props.projectRoot, innerWidth - 2);

  const rows: Row[] = [];
  rows.push({ text: "", color: theme.muted });
  rows.push({ text: `Welcome back, ${greetingName()}!`, color: theme.assistant });
  rows.push({ text: "", color: theme.muted });
  for (const line of EAON_WORDMARK) rows.push({ text: line, color: theme.accent, bold: true });
  rows.push({ text: "", color: theme.muted });
  for (const line of quoteLines) rows.push({ text: line, color: theme.assistant, italic: true });
  rows.push({ text: attribution, color: theme.muted });
  rows.push({ text: "", color: theme.muted });
  for (const line of footerLines) rows.push({ text: line, color: theme.muted });
  rows.push({ text: pathLine, color: theme.muted });

  const tipsPanel = [
    { text: "Tips for getting started", color: theme.accent, bold: true },
    { text: "/init to scan this project and save context", color: theme.muted },
    { text: "/mode agent to start coding", color: theme.muted },
    { text: "Shift+Tab to toggle Sandboxed / Auto", color: theme.muted },
    { text: "", color: theme.muted },
    { text: "Recent sessions", color: theme.accent, bold: true },
    ...(props.recentSessions.length > 0
      ? props.recentSessions.slice(0, 4).map((s) => ({ text: truncateFromLeft(s.title, 42), color: theme.muted }))
      : [{ text: "No recent sessions", color: theme.muted }]),
  ];

  // Side-by-side needs real room: the box's own width, a gap, and a usable
  // tips column — below that, two columns would just wrap illegibly, so
  // stack instead (tips block rendered below the box).
  const tipsWidth = 42;
  const sideBySide = terminalColumns >= boxTotalWidth + 3 + tipsWidth;

  return { innerWidth, boxTotalWidth, topBorder, bottomBorder, rows, tipsPanel, sideBySide };
}

function BoxColumn({ innerWidth, topBorder, bottomBorder, rows }: ReturnType<typeof buildBannerLayout>): React.ReactElement {
  return (
    <Box flexDirection="column">
      <Text color={theme.accent}>{topBorder}</Text>
      {rows.map((row, i) => (
        <Text key={i}>
          <Text color={theme.accent}>│</Text>
          <Text color={row.color} bold={row.bold} italic={row.italic}>
            {padCenter(row.text, innerWidth)}
          </Text>
          <Text color={theme.accent}>│</Text>
        </Text>
      ))}
      <Text color={theme.accent}>{bottomBorder}</Text>
    </Box>
  );
}

function TipsColumn({ tipsPanel }: { tipsPanel: Array<{ text: string; color: string; bold?: boolean }> }): React.ReactElement {
  return (
    <Box flexDirection="column">
      {tipsPanel.map((line, i) => (
        <Text key={i} color={line.color} bold={line.bold}>
          {line.text}
        </Text>
      ))}
    </Box>
  );
}

export function EaonBanner(props: EaonBannerProps): React.ReactElement {
  const { stdout } = useStdout();
  const columns = stdout?.columns ?? 80;
  const layout = buildBannerLayout(props, columns);

  if (layout.sideBySide) {
    return (
      <Box flexDirection="row">
        <BoxColumn {...layout} />
        <Box marginLeft={3} marginTop={1}>
          <TipsColumn tipsPanel={layout.tipsPanel} />
        </Box>
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      <BoxColumn {...layout} />
      <Box marginTop={1}>
        <TipsColumn tipsPanel={layout.tipsPanel} />
      </Box>
    </Box>
  );
}
