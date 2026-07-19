// Request-time history slimming — the biggest practical speed lever for
// local models, where prompt-processing time scales with context length.
// A long agent session accumulates huge tool outputs (file reads, grep
// results, shell logs) that stop mattering a few steps later, but were
// being re-sent to the provider on EVERY subsequent step. Claude Code
// does the same kind of stale-tool-output elision.
//
// This never mutates the stored history: it clones the affected turns at
// request time only, so /resume, /export, and the on-screen transcript all
// keep the full text. The elision note tells the model it can simply
// re-run the tool if it genuinely needs elided output again.

import type { Turn } from "../types.js";

/** The most recent N tool results are always sent in full — they're what
 * the model is actively working from. */
export const RECENT_TOOL_RESULTS_KEPT = 6;

/** Tool results shorter than this are never slimmed — a stub plus a note
 * wouldn't be meaningfully smaller. */
export const SLIM_MIN_CHARS = 400;

const FIRST_LINE_KEPT = 160;

export function slimHistoryForRequest(turns: Turn[]): Turn[] {
  const toolIndices: number[] = [];
  for (let i = 0; i < turns.length; i++) {
    if (turns[i].role === "tool") toolIndices.push(i);
  }
  const slimCount = toolIndices.length - RECENT_TOOL_RESULTS_KEPT;
  if (slimCount <= 0) return turns;

  const slimSet = new Set(toolIndices.slice(0, slimCount));
  return turns.map((t, i) => {
    if (!slimSet.has(i) || t.content.length <= SLIM_MIN_CHARS) return t;
    const firstLine = t.content.split("\n", 1)[0].slice(0, FIRST_LINE_KEPT);
    const elided = t.content.length - firstLine.length;
    return {
      ...t,
      content: `${firstLine}\n…[${elided} chars of this older tool result elided to save context — call the tool again if you need it]`,
    };
  });
}
