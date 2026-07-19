// Shell execution — ported from DesktopControlService.runShell, with the
// shell invocation swapped from a hardcoded /bin/zsh to the cross-platform
// choice in platform.ts. Same guarantees: no sudo, bounded runtime, bounded
// output, and the PEP 668 "externally-managed-environment" pip hint tied
// directly to the command that just failed.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import type { ToolResult } from "../types.js";
import { extraPathEntries, shellInvocation } from "../platform.js";
import { normalizePath, type PathGuardContext } from "./pathGuard.js";

export const SHELL_TIMEOUT_MS = 120_000;
export const SHELL_OUTPUT_CAP = 12_000;

/** Word-boundary sudo detection — catches `sudo …`, `; sudo …`, `| sudo …`
 * but not `sudoku`/`pseudo`. */
export function mentionsSudo(command: string): boolean {
  const lowered = command.toLowerCase();
  if (!lowered.includes("sudo")) return false;
  return /(^|[^a-z0-9_])sudo([^a-z0-9_]|$)/.test(lowered);
}

export function runShell(args: Record<string, unknown>, ctx: PathGuardContext): Promise<ToolResult> {
  const commandRaw = args.command;
  if (typeof commandRaw !== "string" || commandRaw.trim().length === 0) {
    return Promise.resolve({ isError: true, text: 'missing a non-empty "command"' });
  }
  const command = commandRaw.trim();
  if (mentionsSudo(command)) {
    return Promise.resolve({
      isError: true,
      text: "Refused: this runs commands as you, never as root. Drop the sudo — if the task genuinely needs admin rights, ask the user to do it themselves.",
    });
  }

  let workingDirectory = ctx.projectRoot;
  const wdRaw = args.working_directory;
  if (typeof wdRaw === "string" && wdRaw.trim().length > 0) {
    const wd = normalizePath(wdRaw, ctx);
    if (!fs.existsSync(wd) || !fs.statSync(wd).isDirectory()) {
      return Promise.resolve({ isError: true, text: `working_directory isn't a directory: ${wd}` });
    }
    workingDirectory = wd;
  }

  const { cmd, args: shellArgs } = shellInvocation(command);
  const env = { ...process.env };
  const extra = extraPathEntries();
  if (extra.length > 0) {
    env.PATH = `${env.PATH ?? ""}${path.delimiter}${extra.join(path.delimiter)}`;
  }

  return new Promise((resolve) => {
    let settled = false;
    let output = "";
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(cmd, shellArgs, { cwd: workingDirectory, env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      resolve({ isError: true, text: `Couldn't start the command: ${(e as Error).message}` });
      return;
    }

    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      resolve({ isError: true, text: `Timed out after ${SHELL_TIMEOUT_MS / 1000}s and was stopped. A command run this way has to finish on its own.` });
    }, SHELL_TIMEOUT_MS);

    child.stdout?.on("data", (chunk) => { output += chunk.toString("utf8"); });
    child.stderr?.on("data", (chunk) => { output += chunk.toString("utf8"); });

    child.on("error", (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve({ isError: true, text: `Couldn't start the command: ${e.message}` });
    });

    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      const truncated = output.length > SHELL_OUTPUT_CAP
        ? output.slice(0, SHELL_OUTPUT_CAP) + `\n…(output truncated at ${SHELL_OUTPUT_CAP / 1000}k characters)`
        : output;
      const header = `exit code: ${code ?? -1}`;
      let body = truncated.length === 0 ? "(no output)" : truncated;
      if (output.includes("externally-managed-environment")) {
        body += "\n\nHINT: create a project-local virtual environment and use its pip — never --break-system-packages:\npython3 -m venv .venv && .venv/bin/pip install <package>\nThen run the program with .venv/bin/python3 (or .venv\\Scripts\\python.exe on Windows), not a bare python3.";
      }
      const text = `${header}\n${body}`;
      resolve({ isError: code !== 0, text });
    });
  });
}
