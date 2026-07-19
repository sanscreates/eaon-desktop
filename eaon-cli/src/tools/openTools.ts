// App/URL/path/AppleScript tools — Eaon Claw's "wider remit" beyond the
// coding tool set (DesktopTool cases beyond DesktopTool.codingTools).
// Honest about where cross-platform parity genuinely isn't possible: macOS
// resolves an installed app by display name and drives it via AppleScript
// (LaunchServices + Automation) with no equivalent primitive on Windows/
// Linux, so open_app/quit_app degrade to best-effort there rather than
// silently pretending the same reliability.

import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import open from "open";
import type { ToolResult } from "../types.js";
import { isLinux, isMac, isWindows } from "../platform.js";
import { normalizePath, type PathGuardContext } from "./pathGuard.js";

function ok(text: string): ToolResult {
  return { isError: false, text };
}
function err(text: string): ToolResult {
  return { isError: true, text };
}

function execFileP(cmd: string, args: string[]): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 15_000 }, (error, stdout, stderr) => {
      const output = `${stdout}${stderr}`.trim();
      resolve({ code: error ? (typeof error.code === "number" ? error.code : 1) : 0, output });
    });
  });
}

export async function openApp(args: Record<string, unknown>): Promise<ToolResult> {
  const name = typeof args.name === "string" ? args.name.trim() : "";
  if (!name) return err('missing a non-empty "name"');
  if (isMac) {
    const result = await execFileP("/usr/bin/open", ["-a", name]);
    return result.code === 0
      ? ok(`Opened ${name}.`)
      : err(`Couldn't open "${name}": ${result.output || "no application with that name was found."}`);
  }
  if (isWindows) {
    const result = await execFileP("cmd.exe", ["/d", "/s", "/c", "start", "", name]);
    return result.code === 0
      ? ok(`Asked Windows to launch "${name}". (Windows has no reliable launch-by-display-name API from a CLI — this only works if "${name}" is a command on PATH or a registered App Execution Alias. If it didn't actually open, tell the user to launch it manually.)`)
      : err(`Couldn't launch "${name}": ${result.output}`);
  }
  // Linux: best effort — try it as a literal launch command (works for most
  // apps: firefox, code, gimp, …), which is the closest thing to a universal
  // convention across desktop environments.
  const result = await execFileP(name, []);
  return result.code === 0
    ? ok(`Launched "${name}".`)
    : err(`Couldn't launch "${name}" as a command: ${result.output || "not found on PATH"}. Linux has no universal launch-by-display-name API — try the app's actual binary/command name.`);
}

export async function quitApp(args: Record<string, unknown>): Promise<ToolResult> {
  const name = typeof args.name === "string" ? args.name.trim() : "";
  if (!name) return err('missing a non-empty "name"');
  if (isMac) {
    const escaped = name.replace(/"/g, '\\"');
    const result = await execFileP("/usr/bin/osascript", ["-e", `tell application "${escaped}" to quit`]);
    return result.code === 0
      ? ok(`Asked ${name} to quit.`)
      : err(`Couldn't quit "${name}": ${result.output}`);
  }
  if (isWindows) {
    const result = await execFileP("taskkill", ["/IM", name.toLowerCase().endsWith(".exe") ? name : `${name}.exe`, "/F"]);
    return result.code === 0
      ? ok(`Force-closed ${name}. (Windows' taskkill is a hard kill, not a polite quit — any unsaved work in it is lost.)`)
      : err(`Couldn't close "${name}": ${result.output}`);
  }
  const result = await execFileP("pkill", ["-x", name]);
  return result.code === 0
    ? ok(`Closed ${name}. (pkill is a hard kill, not a polite quit — any unsaved work in it is lost.)`)
    : err(`Couldn't close "${name}": ${result.output || "no matching process"}`);
}

export async function openUrl(args: Record<string, unknown>): Promise<ToolResult> {
  const raw = typeof args.url === "string" ? args.url.trim() : "";
  if (!raw) return err('missing a non-empty "url"');
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return err(`Not a valid web URL (needs http:// or https://): ${raw}`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return err(`Not a valid web URL (needs http:// or https://): ${raw}`);
  }
  await open(raw);
  return ok(`Opened ${raw} in the default browser.`);
}

export async function openPath(args: Record<string, unknown>, ctx: PathGuardContext): Promise<ToolResult> {
  const raw = args.path;
  if (typeof raw !== "string") return err('missing "path"');
  const target = normalizePath(raw, ctx);
  if (!fs.existsSync(target)) return err(`No such path: ${target}`);
  const reveal = args.reveal === true;
  if (reveal) {
    if (isMac) {
      await execFileP("/usr/bin/open", ["-R", target]);
      return ok(`Revealed ${target} in Finder.`);
    }
    if (isWindows) {
      await execFileP("explorer.exe", [`/select,${target}`]);
      return ok(`Revealed ${target} in File Explorer.`);
    }
    if (isLinux) {
      // No universal "select in file manager" primitive across desktop
      // environments — degrade honestly to opening the containing folder.
      const parent = fs.statSync(target).isDirectory() ? target : path.dirname(target);
      await open(parent);
      return ok(`Linux has no universal "reveal and select" API — opened the containing folder instead: ${parent}`);
    }
  }
  await open(target);
  return ok(`Opened ${target}.`);
}

export async function runAppleScript(args: Record<string, unknown>): Promise<ToolResult> {
  if (!isMac) return err("AppleScript only runs on macOS.");
  const script = typeof args.script === "string" ? args.script.trim() : "";
  if (!script) return err('missing a non-empty "script"');
  const lines = script.split("\n").flatMap((line) => ["-e", line]);
  const result = await execFileP("/usr/bin/osascript", lines);
  if (result.code === 0) {
    return ok(result.output.length === 0 ? "Done." : result.output);
  }
  return err(`AppleScript failed: ${result.output || "unknown error"}\n(If this needs to control another app, macOS may be asking for Automation/Accessibility permission — check System Settings → Privacy & Security.)`);
}
