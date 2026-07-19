// Update nudge — eaon-cli isn't published to npm; the only real
// distribution channel today is the bundled copy inside Eaon Desktop (see
// EaonCLILauncher.swift on the Mac side, which does the actual Install/
// Update). This just gives a standalone `eaon` session the same heads-up
// without requiring the user to open the app's Settings first.
//
// Best-effort and silent on any failure — a version check must never be
// the reason a terminal session fails to start.

import { existsSync, readFileSync } from "node:fs";
import { isMac } from "./platform.js";

/** Plain dot-separated integer comparison — same algorithm as the Mac
 * app's EaonCLILauncher.isNewerVersion / UpdateChecker.isVersion, so a
 * user never sees the CLI and the app disagree about what "newer" means. */
export function isNewerVersion(candidate: string, current: string): boolean {
  const a = candidate.split(".").map((p) => parseInt(p, 10) || 0);
  const b = current.split(".").map((p) => parseInt(p, 10) || 0);
  const count = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

/** The one place Eaon Desktop bundles a copy of this CLI today — mirrors
 * EaonCLILauncher.bundledPayloadDirectory's Contents/Resources/eaon-cli
 * path. Windows/Linux have no bundled distribution yet, so this is
 * deliberately macOS-only rather than guessing at an equivalent that
 * doesn't exist. */
function bundledAppPackageJSON(): string | null {
  if (!isMac) return null;
  const path = "/Applications/Eaon.app/Contents/Resources/eaon-cli/package.json";
  return existsSync(path) ? path : null;
}

/** Returns the bundled version when it's newer than `currentVersion`, or
 * null when there's nothing to report (no bundled app found, same
 * version, or anything unreadable/malformed). Never throws. */
export function checkForBundledUpdate(currentVersion: string): string | null {
  try {
    const packagePath = bundledAppPackageJSON();
    if (!packagePath) return null;
    const pkg = JSON.parse(readFileSync(packagePath, "utf8"));
    const bundledVersion = typeof pkg.version === "string" ? pkg.version : null;
    if (!bundledVersion || !isNewerVersion(bundledVersion, currentVersion)) return null;
    return bundledVersion;
  } catch {
    return null;
  }
}

/** The one-line notice printed on interactive startup when an update is
 * found — kept out of stdout (which a piped/scripted caller might parse)
 * and off entirely in --print mode (see cli.tsx). */
export function updateNoticeLine(bundledVersion: string): string {
  return `A newer Eaon CLI (v${bundledVersion}) is bundled with Eaon Desktop — update via Settings → Eaon CLI.`;
}
