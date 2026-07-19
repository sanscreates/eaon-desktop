// Session persistence — one JSON file per conversation under
// ~/.eaon/cli/sessions/, atomic write. Backs `/resume` and `--continue`.

import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { sessionsDir } from "../platform.js";
import type { EaonMode, Turn } from "../types.js";

export interface Session {
  id: string;
  title: string;
  mode: EaonMode;
  modelKey: string | null;
  projectRoot: string;
  turns: Turn[];
  createdAt: number;
  updatedAt: number;
}

export function newSession(mode: EaonMode, modelKey: string | null, projectRoot: string): Session {
  const now = Date.now();
  return { id: randomUUID(), title: "New session", mode, modelKey, projectRoot, turns: [], createdAt: now, updatedAt: now };
}

function sessionFile(id: string): string {
  return path.join(sessionsDir(), `${id}.json`);
}

export function saveSession(session: Session): void {
  const dir = sessionsDir();
  fs.mkdirSync(dir, { recursive: true });
  session.updatedAt = Date.now();
  const file = sessionFile(session.id);
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(session, null, 2), "utf8");
  fs.renameSync(tmp, file);
}

export function loadSession(id: string): Session | null {
  try {
    const raw = fs.readFileSync(sessionFile(id), "utf8");
    return JSON.parse(raw) as Session;
  } catch {
    return null;
  }
}

export interface SessionSummary {
  id: string;
  title: string;
  mode: EaonMode;
  updatedAt: number;
  turnCount: number;
}

export function listSessions(limit = 20): SessionSummary[] {
  const dir = sessionsDir();
  let files: string[];
  try {
    files = fs.readdirSync(dir).filter((f) => f.endsWith(".json") && !f.endsWith(".tmp"));
  } catch {
    return [];
  }
  const sessions: SessionSummary[] = [];
  for (const file of files) {
    try {
      const raw = fs.readFileSync(path.join(dir, file), "utf8");
      const session = JSON.parse(raw) as Session;
      sessions.push({ id: session.id, title: session.title, mode: session.mode, updatedAt: session.updatedAt, turnCount: session.turns.length });
    } catch {
      // Skip a corrupt/partial file rather than failing the whole list.
    }
  }
  return sessions.sort((a, b) => b.updatedAt - a.updatedAt).slice(0, limit);
}

/** First user message, trimmed to a short title — same idea as the Mac
 * app's placeholder-title derivation. */
export function deriveTitle(turns: Turn[]): string {
  const firstUser = turns.find((t) => t.role === "user");
  if (!firstUser) return "New session";
  const oneLine = firstUser.content.replace(/\s+/g, " ").trim();
  return oneLine.length > 60 ? oneLine.slice(0, 57) + "…" : oneLine || "New session";
}
