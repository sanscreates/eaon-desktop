// Memory — the cross-platform port of the Mac app's MemoryExtractor +
// MemoryStore. Eaon silently mines durable facts about the user from a chat
// exchange (a background, non-streaming model call), stores them, and injects
// them into future chats so it feels like it remembers you. Same extraction
// prompt and "what qualifies" rules as macOS, so behavior matches.

import type { Memory } from "./types";

export interface ExtractedMemory {
  kind: "fact" | "event";
  text: string;
}

/** The shared "what to remember" contract — identical to the Mac app's, so
 *  per-turn extraction never drifts from what the desktop app would keep. */
const WHAT_TO_REMEMBER = `Reply with ONLY a JSON array (no markdown, no commentary) of objects like {"kind": "fact", "text": "..."} or {"kind": "event", "text": "..."}.
- "fact": durable — their name, role, location, relationships, preferences, ongoing projects, things that stay true.
- "event": a happening in their life a thoughtful friend would remember and ask about later — a trip, an exam, an interview, weekend plans, something they're excited or worried about. Keep any stated timing in the text (e.g. "has a math final on Friday").
Never include: one-off requests to the assistant (like a coding task), facts about the assistant, anything already in the known list, guesses, or sensitive details (health, finances, other people's private information) beyond what the user plainly volunteered.
Reply with [] if nothing qualifies.`;

export const MEMORY_SYSTEM_PROMPT = `You silently extract things worth remembering about a user, from one exchange of a chat, for a personalization feature.
${WHAT_TO_REMEMBER}`;

/** The user prompt for one exchange — the known facts, then the latest turn. */
export function buildExtractionPrompt(userText: string, assistantText: string, existing: string[]): string {
  const known = existing.length ? existing.map((t) => `- ${t}`).join("\n") : "(nothing yet)";
  return `Already known about the user:
${known}

Latest exchange:
User: ${userText}
Assistant: ${assistantText}

JSON array of NEW items worth remembering, or []:`;
}

/** Tolerant parse of the model's reply into memories — pulls the first JSON
 *  array even if the model wrapped it in prose or a ```json fence. */
export function parseExtraction(raw: string): ExtractedMemory[] {
  const start = raw.indexOf("[");
  const end = raw.lastIndexOf("]");
  if (start === -1 || end === -1 || end < start) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.slice(start, end + 1));
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: ExtractedMemory[] = [];
  for (const item of parsed) {
    if (item && typeof item === "object" && typeof (item as any).text === "string") {
      const text = (item as any).text.trim();
      const kind = (item as any).kind === "event" ? "event" : "fact";
      if (text) out.push({ kind, text });
    }
  }
  return out;
}

/** The system-message block injected into every request when memory is on. */
export function memoryBlock(memories: Memory[]): string {
  if (!memories.length) return "";
  const lines = memories.map((m) => `- ${m.text}`).join("\n");
  return `Things you remember about the user (from past conversations — use naturally, don't recite):\n${lines}`;
}

/** Case/space-insensitive dedup key so the same fact isn't stored twice. */
export function memoryKey(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}
