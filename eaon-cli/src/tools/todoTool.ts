// The todo tool — the model plans multi-step work as an explicit checklist
// it updates as it goes (the same pattern Claude Code's TodoWrite uses).
// State is per-process, per-session: /clear resets it. The result text IS
// the rendered checklist, so the existing tool-row display shows live
// progress with zero new UI machinery; the App additionally reads
// `currentTodos()` to pin the list above the composer while items remain.

import type { ToolResult } from "../types.js";

export type TodoStatus = "pending" | "in_progress" | "completed";

export interface TodoItem {
  content: string;
  status: TodoStatus;
}

let todos: TodoItem[] = [];

export function currentTodos(): TodoItem[] {
  return todos;
}

export function resetTodos(): void {
  todos = [];
}

const MARKS: Record<TodoStatus, string> = {
  pending: "☐",
  in_progress: "◐",
  completed: "☑",
};

export function renderTodos(items: TodoItem[]): string {
  if (items.length === 0) return "(no todos)";
  return items.map((t) => `${MARKS[t.status]} ${t.content}`).join("\n");
}

export function writeTodos(args: Record<string, unknown>): ToolResult {
  const raw = args.todos;
  if (!Array.isArray(raw)) {
    return { isError: true, text: 'ERROR: "todos" must be an array of {content, status} items — send the COMPLETE list each time, not a diff.' };
  }
  const parsed: TodoItem[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) continue;
    const content = (item as Record<string, unknown>).content;
    const status = (item as Record<string, unknown>).status;
    if (typeof content !== "string" || content.trim().length === 0) continue;
    const normalized: TodoStatus = status === "completed" ? "completed" : status === "in_progress" ? "in_progress" : "pending";
    parsed.push({ content: content.trim(), status: normalized });
  }
  todos = parsed;
  return { isError: false, text: renderTodos(parsed) };
}
