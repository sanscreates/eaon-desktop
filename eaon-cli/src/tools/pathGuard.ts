// Path safety — the code-enforced half of tool safety (the other half is
// the permission-confirmation UI). Adapted from DesktopControlService's
// normalizedPath/isModifiablePath (DesktopControl.swift), with one
// deliberate change: the Mac app is always home-rooted (it has no notion of
// "the current project"); a terminal tool naturally does, so the allow-list
// here is home dir + the project root (cwd at launch, or --cwd) + the OS
// temp dir, and relative paths resolve against the project root instead of
// requiring an absolute path under home every time.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isWindows, tempDir } from "../platform.js";

export interface PathGuardContext {
  /** The project root — cwd at launch, or --cwd. Relative tool paths resolve
   * against this, and it's always itself an allowed write location. */
  projectRoot: string;
}

function expandHome(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed === "~") return os.homedir();
  if (trimmed.startsWith("~/") || trimmed.startsWith("~\\")) {
    return path.join(os.homedir(), trimmed.slice(2));
  }
  return trimmed;
}

/** Resolves symlinks on the longest EXISTING prefix of a path, then
 * re-appends whatever doesn't exist yet — so a not-yet-created file/folder
 * still normalizes correctly, while a symlinked existing ancestor can't be
 * used to escape the guard (mirrors resolvingSymlinksInPath, which requires
 * the full path to exist; this variant tolerates new paths). */
function realpathExistingPrefix(target: string): string {
  let current = path.normalize(target);
  const trailing: string[] = [];
  // Bounded by path depth — never actually loops more than the number of
  // path segments.
  for (let i = 0; i < 200; i++) {
    try {
      const real = fs.realpathSync(current);
      return trailing.length ? path.join(real, ...trailing.reverse()) : real;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return path.normalize(target); // hit the root, nothing real found
      trailing.push(path.basename(current));
      current = parent;
    }
  }
  return path.normalize(target);
}

/** Expands ~, resolves relative paths against the project root, and
 * resolves symlinks so `~/../../System` or a symlink can't fool the guard. */
export function normalizePath(raw: string, ctx: PathGuardContext): string {
  const expanded = expandHome(raw);
  const absolute = path.isAbsolute(expanded) ? expanded : path.resolve(ctx.projectRoot, expanded);
  return realpathExistingPrefix(absolute);
}

const POSIX_PROTECTED_ROOTS = ["/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/Library", "/opt", "/cores"];
const WINDOWS_PROTECTED_ROOTS = ["c:\\windows", "c:\\program files", "c:\\program files (x86)", "c:\\programdata"];

function isWithin(target: string, base: string): boolean {
  if (target === base) return true;
  const rel = path.relative(base, target);
  return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
}

/** True for a path safe to modify — under the project root, the user's
 * home, or the OS temp dir, and not inside a protected system root. */
export function isModifiablePath(normalized: string, ctx: PathGuardContext): boolean {
  const root = path.parse(normalized).root;
  if (normalized === root) return false;

  const tmp = realpathExistingPrefix(tempDir());
  // Temp is always allowed outright, checked first — otherwise, on macOS,
  // os.tmpdir()'s real path (/private/var/folders/...) would collide with
  // the /private/var protected-root veto below.
  if (isWithin(normalized, tmp)) return true;

  if (isWindows) {
    const lower = normalized.toLowerCase();
    if (WINDOWS_PROTECTED_ROOTS.some((p) => lower === p || lower.startsWith(p + "\\"))) return false;
  } else {
    if (POSIX_PROTECTED_ROOTS.some((p) => normalized === p || normalized.startsWith(p + "/"))) return false;
  }

  const home = realpathExistingPrefix(os.homedir());
  const projectRoot = realpathExistingPrefix(ctx.projectRoot);
  return isWithin(normalized, home) || isWithin(normalized, projectRoot);
}

/** Returns a user-facing refusal, or null if the path is fine to modify. */
export function guardModifiable(normalized: string, action: string, ctx: PathGuardContext): string | null {
  if (isModifiablePath(normalized, ctx)) return null;
  return `Refused: ${action} is only allowed on paths under the project folder (${ctx.projectRoot}), your home folder, or the system temp folder — not "${normalized}", which is a system or out-of-scope location.`;
}
