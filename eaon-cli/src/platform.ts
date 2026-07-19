// Every OS-specific decision in the whole CLI lives here — nowhere else
// should branch on process.platform directly, so a cross-platform gap is
// easy to audit for by grepping this one file.

import os from "node:os";
import path from "node:path";

export const isWindows = process.platform === "win32";
export const isMac = process.platform === "darwin";
export const isLinux = process.platform === "linux";

export function homeDir(): string {
  return os.homedir();
}

export function configDir(): string {
  return path.join(homeDir(), ".eaon", "cli");
}

export function sessionsDir(): string {
  return path.join(configDir(), "sessions");
}

/** The real OS temp dir (macOS: a per-process /var/folders/.../T path, not
 * literally /tmp — resolved via realpath in the path guard, not assumed). */
export function tempDir(): string {
  return os.tmpdir();
}

/** How to invoke a shell command on this OS, matching Node's own
 * child_process.exec conventions so behavior is unsurprising. */
export function shellInvocation(command: string): { cmd: string; args: string[] } {
  if (isWindows) {
    return { cmd: process.env.COMSPEC || "cmd.exe", args: ["/d", "/s", "/c", command] };
  }
  const shell = process.env.SHELL && process.env.SHELL.length > 0 ? process.env.SHELL : "/bin/bash";
  return { cmd: shell, args: ["-c", command] };
}

/** Extra PATH entries a GUI-less launch can still miss on each OS (Homebrew
 * on Apple Silicon, user-local pip/npm bins). Mirrors LocalAIManager's
 * resolveBinary search list. Deduped by the caller against the real PATH. */
export function extraPathEntries(): string[] {
  if (isWindows) return [];
  const home = homeDir();
  return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", path.join(home, ".local", "bin")];
}

export function platformLabel(): string {
  if (isMac) return "macOS";
  if (isWindows) return "Windows";
  if (isLinux) return "Linux";
  return process.platform;
}
