// Read-before-edit tracking — the same discipline Claude Code enforces:
// a model shouldn't blind-overwrite or edit a file it hasn't actually
// looked at this session, because it's almost certainly guessing at the
// current contents. A file becomes "known" once it's been read (read_file)
// or written by the agent itself (write_file/edit_file) — so a file the
// model just created is fine to edit, but a pre-existing file it's never
// seen gets a one-time nudge to read it first.
//
// State is per-process, per-session (reset by /clear and /resume), keyed by
// the normalized absolute path so "src/x.ts" and "./src/x.ts" are the same
// file.

const known = new Set<string>();

export function markFileKnown(normalizedPath: string): void {
  known.add(normalizedPath);
}

export function isFileKnown(normalizedPath: string): boolean {
  return known.has(normalizedPath);
}

export function resetKnownFiles(): void {
  known.clear();
}
