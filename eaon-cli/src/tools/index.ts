// The tool catalog — schemas, per-mode subsets, execution dispatch, and
// confirmation-dialog text. Ported from DesktopTool/DesktopControlTool/
// DesktopControlService (DesktopControl.swift): same tool names, same
// argument shapes, same safety semantics, so prompts and habits carry over
// exactly between Eaon's macOS app and this CLI.

import { isMac } from "../platform.js";
import type { PathGuardContext } from "./pathGuard.js";
import * as fsTools from "./fsTools.js";
import * as openTools from "./openTools.js";
import { runShell } from "./shellTool.js";
import { globSearch, grepSearch } from "./searchTools.js";
import { writeTodos } from "./todoTool.js";
import type { ToolDefinition, ToolResult } from "../types.js";

export type ToolName =
  | "list_directory" | "move_item" | "create_folder" | "write_file" | "edit_file" | "read_file"
  | "grep" | "glob" | "todo_write"
  | "trash_item" | "run_shell" | "open_app" | "quit_app" | "open_url" | "open_path" | "run_applescript";

interface ToolSpec {
  name: ToolName;
  description: string;
  parameters: ToolDefinition["parameters"];
  readOnly?: boolean;
  /** Only offered when this returns true for the current platform. */
  available?: () => boolean;
}

const str = (description: string) => ({ type: "string", description });

const SPECS: ToolSpec[] = [
  {
    name: "list_directory", readOnly: true,
    description: "List the files and folders inside a directory.",
    parameters: { type: "object", properties: { path: str("Path of the directory to list, e.g. src or /Users/you/project. Relative paths resolve against the project folder. ~ is expanded.") }, required: ["path"] },
  },
  {
    name: "move_item",
    description: "Move or rename a file or folder.",
    parameters: { type: "object", properties: {
      from: str("Path of the file or folder to move."),
      to: str("Destination path. To rename, give the new name as the last path component."),
    }, required: ["from", "to"] },
  },
  {
    name: "create_folder",
    description: "Create a new folder (and any missing parent folders). Safe to call on a folder that already exists.",
    parameters: { type: "object", properties: { path: str("Path of the folder to create.") }, required: ["path"] },
  },
  {
    name: "write_file",
    description: "Write text to a file, creating it (and parent folders) or overwriting it. Always send the COMPLETE file content, never a fragment.",
    parameters: { type: "object", properties: {
      path: str("Path of the file to write, e.g. src/snake.py. Relative paths resolve against the project folder."),
      content: str("The full text contents to write. Overwrites the file if it already exists."),
    }, required: ["path", "content"] },
  },
  {
    name: "edit_file",
    description: "Replace an exact occurrence of text inside an existing file — the precise way to make a small change without rewriting the whole file. Matches exactly once by default; set replace_all to change every occurrence.",
    parameters: { type: "object", properties: {
      path: str("Path of the file to edit."),
      search: str("The exact existing text to find, copied character-for-character from the file (use read_file first if unsure). Must occur exactly once unless replace_all is true."),
      replace: str("The replacement text. An empty string deletes the matched text."),
      replace_all: { type: "boolean", description: "If true, replace every occurrence of the search text instead of requiring it to be unique." },
    }, required: ["path", "search", "replace"] },
  },
  {
    name: "read_file",
    description: "Read a text file's contents back. For a big file, read a slice with offset/limit instead of the whole thing.",
    parameters: { type: "object", properties: {
      path: str("Path of the text file to read."),
      offset: { type: "number", description: "1-based line number to start reading from. Omit to start at the top." },
      limit: { type: "number", description: "Maximum number of lines to return. Omit for all (long files are still capped)." },
    }, required: ["path"] },
  },
  {
    name: "grep", readOnly: true,
    description: "Search file CONTENTS with a regular expression — the fast way to find where something is defined, used, or mentioned across a codebase. Returns file:line: matching-line rows. Skips node_modules/.git/build output automatically.",
    parameters: { type: "object", properties: {
      pattern: str("A regular expression to search for, e.g. \"function handleSubmit\" or \"TODO|FIXME\"."),
      path: str("Optional file or directory to search in. Defaults to the project root."),
      include: str('Optional filename glob to restrict the search, e.g. "*.ts" or "src/**/*.py".'),
    }, required: ["pattern"] },
  },
  {
    name: "glob", readOnly: true,
    description: "Find FILES by name pattern (*, **, ?) — e.g. \"**/*.test.ts\" or \"src/*.swift\". Results are sorted most-recently-modified first. Use grep instead when you're searching by content.",
    parameters: { type: "object", properties: {
      pattern: str('The glob pattern to match file paths against, e.g. "**/*.ts".'),
      path: str("Optional directory to search under. Defaults to the project root."),
    }, required: ["pattern"] },
  },
  {
    name: "todo_write", readOnly: true,
    description: "Maintain your task checklist for multi-step work. Send the COMPLETE current list every time (not a diff). Use it when a task has 3+ distinct steps: add items up front, mark exactly one in_progress while you work on it, and mark items completed the moment they're done.",
    parameters: { type: "object", properties: {
      todos: {
        type: "array",
        description: "The full todo list, replacing whatever was there before.",
        items: { type: "object", properties: {
          content: { type: "string", description: "The task, imperative and short." },
          status: { type: "string", enum: ["pending", "in_progress", "completed"], description: "Where this task stands right now." },
        }, required: ["content", "status"] },
      },
    }, required: ["todos"] },
  },
  {
    name: "trash_item",
    description: "Move a file or folder to the Trash/Recycle Bin (recoverable — never a permanent delete).",
    parameters: { type: "object", properties: { path: str("Path of the file or folder to trash.") }, required: ["path"] },
  },
  {
    name: "run_shell",
    description: "Run a shell command. No sudo. Times out and caps its own output.",
    parameters: { type: "object", properties: {
      command: str("The shell command to run, exactly as you'd type it in a terminal."),
      working_directory: str("Optional path to run in. Defaults to the project folder."),
    }, required: ["command"] },
  },
  {
    name: "open_app", available: () => true,
    description: "Open (launch or focus) an application by name.",
    parameters: { type: "object", properties: { name: str('Application name, e.g. "Visual Studio Code".') }, required: ["name"] },
  },
  {
    name: "quit_app", available: () => true,
    description: "Quit/close an application by name.",
    parameters: { type: "object", properties: { name: str("Application name to quit.") }, required: ["name"] },
  },
  {
    name: "open_url",
    description: "Open a URL in the default web browser.",
    parameters: { type: "object", properties: { url: str("A full URL including scheme, e.g. https://example.com.") }, required: ["url"] },
  },
  {
    name: "open_path",
    description: "Open a file or folder with its default app, or reveal it in the system file manager.",
    parameters: { type: "object", properties: {
      path: str("Path of the file or folder to open."),
      reveal: { type: "boolean", description: "If true, reveal the item in the file manager instead of opening it." },
    }, required: ["path"] },
  },
  {
    name: "run_applescript", available: () => isMac,
    description: "Run an AppleScript — the reliable way to control scriptable Mac apps and click menu items by name. macOS only.",
    parameters: { type: "object", properties: { script: str("The AppleScript source to run.") }, required: ["script"] },
  },
];

const SPEC_BY_NAME = new Map(SPECS.map((s) => [s.name, s]));

/** The coding core of the Agent's tool set — kept as its own list because
 * the system prompt teaches these first, in this order. */
export const CODING_TOOLS: ToolName[] = ["grep", "glob", "read_file", "write_file", "edit_file", "run_shell", "list_directory", "create_folder", "move_item", "todo_write", "open_path"];

/** Everything this platform can actually do — Agent's full catalog. Eaon
 * Claw used to be a separate mode holding the wider (app/URL/AppleScript)
 * tools; it's folded into Agent now, matching the same merge in Eaon
 * Desktop, so Agent is the one mode that acts on the machine. */
export function agentTools(): ToolName[] {
  return SPECS.filter((s) => !s.available || s.available()).map((s) => s.name);
}

export function toolsForMode(mode: "chat" | "agent" | "claw"): ToolName[] {
  if (mode === "chat") return [];
  // "claw" only ever arrives from an old saved session — same catalog now.
  return agentTools();
}

export function toolDefinitions(names: ToolName[]): ToolDefinition[] {
  return names.map((name) => {
    const spec = SPEC_BY_NAME.get(name)!;
    return { name: spec.name, description: spec.description, parameters: spec.parameters, readOnly: spec.readOnly };
  });
}

export function isReadOnlyTool(name: string): boolean {
  return SPEC_BY_NAME.get(name as ToolName)?.readOnly === true;
}

export function isKnownTool(name: string): name is ToolName {
  return SPEC_BY_NAME.has(name as ToolName);
}

/** Names models actually emit for our tools when they're not paying close
 * attention — observed live ("write" for write_file cost a whole corrective
 * round-trip) plus the conventions other agent harnesses have trained
 * models on (cat/ls/bash/str_replace…). Resolving these instead of
 * bouncing them saves a full model round-trip per slip, which on a local
 * model is seconds. Only unambiguous mappings belong here — nothing where
 * we'd be guessing which tool was meant. */
const TOOL_ALIASES: Record<string, ToolName> = {
  read: "read_file", cat: "read_file", view: "read_file", open_file: "read_file",
  write: "write_file", create_file: "write_file", save_file: "write_file", save: "write_file",
  edit: "edit_file", replace: "edit_file", str_replace: "edit_file", str_replace_editor: "edit_file", modify: "edit_file",
  bash: "run_shell", shell: "run_shell", sh: "run_shell", exec: "run_shell", execute: "run_shell",
  terminal: "run_shell", run: "run_shell", run_command: "run_shell", command: "run_shell",
  ls: "list_directory", list: "list_directory", list_dir: "list_directory", list_files: "list_directory", dir: "list_directory",
  search: "grep", search_files: "grep", search_code: "grep", rg: "grep", ripgrep: "grep", grep_search: "grep", code_search: "grep",
  find: "glob", find_files: "glob", file_search: "glob", glob_search: "glob",
  mkdir: "create_folder", make_dir: "create_folder", make_directory: "create_folder", create_directory: "create_folder", create_dir: "create_folder",
  mv: "move_item", move: "move_item", rename: "move_item", rename_file: "move_item", move_file: "move_item",
  rm: "trash_item", del: "trash_item", delete: "trash_item", remove: "trash_item", trash: "trash_item", delete_file: "trash_item",
  todo: "todo_write", todos: "todo_write", todowrite: "todo_write", update_todos: "todo_write", todo_list: "todo_write", task_list: "todo_write",
  osascript: "run_applescript", applescript: "run_applescript",
  reveal: "open_path", open_folder: "open_path", show_file: "open_path",
  launch_app: "open_app", start_app: "open_app", launch: "open_app",
  browser: "open_url", open_browser: "open_url", web_open: "open_url",
};

/** Canonical tool name for whatever the model called it — exact name first,
 * then the alias table. Null means genuinely unknown (the corrective-error
 * path, which lists the real names, still handles that). */
export function resolveToolName(raw: string): ToolName | null {
  const name = raw.trim().toLowerCase();
  if (SPEC_BY_NAME.has(name as ToolName)) return name as ToolName;
  return TOOL_ALIASES[name] ?? null;
}

/** Every alias key — handed to the fence parser so an attributed fence
 * (tool="write") is captured for alias resolution instead of being left in
 * the prose as if it weren't a call at all. */
export function toolAliasNames(): string[] {
  return Object.keys(TOOL_ALIASES);
}

function lastComponent(p: string): string {
  const parts = p.split(/[/\\]/);
  return parts[parts.length - 1] || p;
}

/** Short human-readable line for the confirmation prompt. */
export function confirmationSummary(name: ToolName, args: Record<string, unknown>): string {
  const s = (key: string) => (typeof args[key] === "string" ? (args[key] as string) : "?");
  switch (name) {
    case "list_directory": return `List ${s("path")}`;
    case "move_item": return `Move ${lastComponent(s("from"))} → ${s("to")}`;
    case "create_folder": return `Create folder ${s("path")}`;
    case "write_file": return `Write file: ${s("path")}`;
    case "edit_file": return `Edit file: ${s("path")}`;
    case "read_file": return `Read file: ${s("path")}`;
    case "grep": return `Search for /${s("pattern")}/${typeof args.include === "string" ? ` in ${args.include}` : ""}`;
    case "glob": return `Find files: ${s("pattern")}`;
    case "todo_write": return "Update todo list";
    case "trash_item": return `Move to Trash: ${s("path")}`;
    case "run_shell": return "Run shell command";
    case "open_app": return `Open app: ${s("name")}`;
    case "quit_app": return `Quit app: ${s("name")}`;
    case "open_url": return `Open URL: ${s("url")}`;
    case "open_path": return (args.reveal === true ? "Reveal: " : "Open: ") + s("path");
    case "run_applescript": return "Run AppleScript";
  }
}

function shorten(value: string, max = 48): string {
  const oneLine = value.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? oneLine.slice(0, max - 1) + "…" : oneLine;
}

/** Compact `Tool(primaryArg)` label, Claude-Code style — what shows next to
 * the ● bullet on a tool row. Deliberately terser than confirmationSummary
 * (which is a full sentence for the permission dialog): here the ● and the
 * indentation already carry the "this is a tool call" meaning. */
export function toolInvocationLabel(name: ToolName, args: Record<string, unknown>): string {
  const s = (key: string) => (typeof args[key] === "string" ? (args[key] as string) : "");
  switch (name) {
    case "read_file": return `Read(${lastComponent(s("path"))})`;
    case "write_file": return `Write(${lastComponent(s("path"))})`;
    case "edit_file": return `Edit(${lastComponent(s("path"))})`;
    case "list_directory": return `List(${lastComponent(s("path")) || "."})`;
    case "create_folder": return `Create dir(${lastComponent(s("path"))})`;
    case "move_item": return `Move(${lastComponent(s("from"))} → ${lastComponent(s("to"))})`;
    case "trash_item": return `Trash(${lastComponent(s("path"))})`;
    case "grep": return `Grep(${shorten(s("pattern"), 40)})`;
    case "glob": return `Glob(${shorten(s("pattern"), 40)})`;
    case "todo_write": return "Update todos";
    case "run_shell": return `Bash(${shorten(s("command"), 52)})`;
    case "open_app": return `Open app(${shorten(s("name"), 30)})`;
    case "quit_app": return `Quit app(${shorten(s("name"), 30)})`;
    case "open_url": return `Open URL(${shorten(s("url"), 44)})`;
    case "open_path": return `${args.reveal === true ? "Reveal" : "Open"}(${lastComponent(s("path"))})`;
    case "run_applescript": return "AppleScript";
  }
}

/** Fuller detail shown under the summary in the confirmation prompt. */
export function confirmationDetail(name: ToolName, args: Record<string, unknown>): string | undefined {
  switch (name) {
    case "run_shell": return typeof args.command === "string" ? args.command : undefined;
    case "run_applescript": return typeof args.script === "string" ? args.script : undefined;
    case "write_file": return typeof args.content === "string" ? args.content : undefined;
    case "edit_file": {
      const search = args.search, replace = args.replace;
      if (typeof search !== "string" || typeof replace !== "string") return undefined;
      return `FIND:\n${search}\n\nREPLACE WITH:\n${replace.length === 0 ? "(delete it)" : replace}`;
    }
    default: return undefined;
  }
}

export async function executeTool(name: ToolName, args: Record<string, unknown>, ctx: PathGuardContext): Promise<ToolResult> {
  switch (name) {
    case "list_directory": return fsTools.listDirectory(args, ctx);
    case "move_item": return fsTools.moveItem(args, ctx);
    case "create_folder": return fsTools.createFolder(args, ctx);
    case "write_file": return fsTools.writeFile(args, ctx);
    case "edit_file": return fsTools.editFile(args, ctx);
    case "read_file": return fsTools.readFile(args, ctx);
    case "grep": return grepSearch(args, ctx);
    case "glob": return globSearch(args, ctx);
    case "todo_write": return writeTodos(args);
    case "trash_item": return fsTools.trashItem(args, ctx);
    case "run_shell": return runShell(args, ctx);
    case "open_app": return openTools.openApp(args);
    case "quit_app": return openTools.quitApp(args);
    case "open_url": return openTools.openUrl(args);
    case "open_path": return openTools.openPath(args, ctx);
    case "run_applescript": return openTools.runAppleScript(args);
  }
}
