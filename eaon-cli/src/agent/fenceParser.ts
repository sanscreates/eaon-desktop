// Text-fallback tool-call parsing, for a model with no native function-
// calling support (or one that ignores the tools array). Ported lessons
// from WorkspaceParser (CodeWorkspace.swift) and its real-transcript fixes:
// a reasoning model's closing </think> commonly glues directly to the next
// fence on one physical line, invisible to a line-based scanner unless
// completed <think> spans are stripped first (which relocates the fence to
// a fresh line); the fence must start its own line; a reply that's only
// reasoning with nothing after it must be treated as a stall, not silence.

const THINK_TAGS = ["think", "thinking"];

/** Removes fully-closed <think>/<thinking> spans, replacing each with a
 * single newline — so a fence glued to the closing tag lands back at true
 * line start, and a fence merely quoted inside reasoning never fires (it
 * disappears along with the rest of the span). An unclosed trailing span
 * (still mid-stream) is left untouched. */
export function stripCompletedThinkSpans(text: string): string {
  let result = text;
  for (const tag of THINK_TAGS) {
    result = result.replace(new RegExp(`<${tag}>[\\s\\S]*?</${tag}>`, "gi"), "\n");
  }
  return result;
}

function hasUnclosedThinkTag(text: string): boolean {
  for (const tag of THINK_TAGS) {
    const opens = (text.match(new RegExp(`<${tag}>`, "gi")) ?? []).length;
    const closes = (text.match(new RegExp(`</${tag}>`, "gi")) ?? []).length;
    if (opens > closes) return true;
  }
  return false;
}

/** True when a full assistant reply is nothing but thinking — no tool call
 * and no real visible text once completed think spans (and any trailing
 * unclosed one) are accounted for. A genuinely empty reply is NOT
 * "thinking only" — that's a different failure, handled separately. */
export function isThinkingOnlyReply(rawContent: string): boolean {
  if (rawContent.trim().length === 0) return false;
  if (hasUnclosedThinkTag(rawContent)) return true;
  return stripCompletedThinkSpans(rawContent).trim().length === 0;
}

export interface FenceToolCall {
  name: string;
  /** Raw text between the fences, unparsed — the caller JSON-parses this
   * through the exact same error-recovery path a native tool call's
   * arguments go through, so there's one malformed-JSON story, not two. */
  argumentsRaw: string;
}

export interface FenceParseResult {
  calls: FenceToolCall[];
  /** Content with matched tool-call fences removed (prose kept) — what
   * actually gets replayed into history, so the model never sees its own
   * fence syntax echoed back as if it were prose. */
  cleanedContent: string;
}

function matchOpenFence(line: string, known: ReadonlySet<string>, attributedOnly: ReadonlySet<string>): string | null {
  const trimmed = line.trim();
  // Attributed form (`tool="name"` / 'name' / unquoted): explicit intent,
  // so alias names are allowed here too — the loop canonicalizes them.
  let m = trimmed.match(/^```(?:eaon:)?computer\s+tool=["']?([a-zA-Z_][a-zA-Z0-9_]*)["']?\s*$/);
  if (m && (known.has(m[1]) || attributedOnly.has(m[1]))) return m[1];
  // Bare-name form: canonical names ONLY. Aliases like "bash"/"sh" collide
  // with ordinary code-fence language tags — a ```bash block in prose must
  // stay prose, never silently become a run_shell call.
  m = trimmed.match(/^```(?:eaon:)?([a-zA-Z_]+)\s*$/);
  if (m && known.has(m[1])) return m[1];
  return null;
}

/** Scans line-by-line (never matches a fence glued to other text on the
 * same line — call stripCompletedThinkSpans first so a think-glued fence
 * still lands at true line start) for `​```eaon:computer tool="name"`, the
 * prefixless `​```computer tool="name"`, and the bare-name shorthand
 * `​```name` / `​```eaon:name`, closed by a lone `​``` ` line.
 * `aliasNames` are additionally accepted in the attributed (tool=) form
 * only — see matchOpenFence for why the bare form stays canonical. */
export function parseFenceToolCalls(content: string, knownToolNames: readonly string[], aliasNames: readonly string[] = []): FenceParseResult {
  const known = new Set(knownToolNames);
  const attributedOnly = new Set(aliasNames);
  const lines = content.split("\n");
  const calls: FenceToolCall[] = [];
  const keptLines: string[] = [];

  let i = 0;
  while (i < lines.length) {
    const name = matchOpenFence(lines[i], known, attributedOnly);
    if (name) {
      const bodyLines: string[] = [];
      let j = i + 1;
      let closed = false;
      while (j < lines.length) {
        if (lines[j].trim() === "```") {
          closed = true;
          break;
        }
        bodyLines.push(lines[j]);
        j++;
      }
      if (closed) {
        calls.push({ name, argumentsRaw: bodyLines.join("\n") });
        i = j + 1;
        continue;
      }
      // Unclosed — likely still streaming or malformed; leave untouched
      // rather than silently swallowing it.
    }
    keptLines.push(lines[i]);
    i++;
  }

  return { calls, cleanedContent: keptLines.join("\n") };
}
