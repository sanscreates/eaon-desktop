// Faithful TypeScript port of the Mac app's message-content pipeline:
// ReasoningExtractor (AssistantMessageContentView.swift), MessageContentParser
// (code-fence splitting), and MarkdownLineParser (MarkdownBlockView.swift) —
// same block grammar (headings, bullets, numbered, quotes, tables, rules)
// and the same inline treatment (bold/italic/`code`/links), so a reply
// renders identically on both platforms.

// ---------------------------------------------------------------------------
// Reasoning extraction — <think>…</think> spans
// ---------------------------------------------------------------------------

export interface ReasoningResult {
  reasoning: string | null;
  visibleContent: string;
  isReasoningInProgress: boolean;
}

export function extractReasoning(raw: string): ReasoningResult {
  const openIdx = raw.indexOf("<think>");
  if (openIdx === -1) return { reasoning: null, visibleContent: raw, isReasoningInProgress: false };
  const before = raw.slice(0, openIdx);
  const afterOpen = raw.slice(openIdx + "<think>".length);
  const closeIdx = afterOpen.indexOf("</think>");
  if (closeIdx !== -1) {
    const reasoning = afterOpen.slice(0, closeIdx).trim();
    const after = afterOpen.slice(closeIdx + "</think>".length);
    const visible = [before.trim(), after.trim()].filter(Boolean).join("\n\n");
    return { reasoning, visibleContent: visible, isReasoningInProgress: false };
  }
  return { reasoning: afterOpen.trim(), visibleContent: before.trim(), isReasoningInProgress: true };
}

// ---------------------------------------------------------------------------
// Code-fence splitting — MessageContentParser port
// ---------------------------------------------------------------------------

export type MessageBlock =
  | { type: "text"; content: string }
  | { type: "code"; language: string | null; content: string };

export function parseMessageBlocks(input: string): MessageBlock[] {
  if (!input.includes("```")) return input ? [{ type: "text", content: input }] : [];
  const segments = input.split("```");
  const blocks: MessageBlock[] = [];
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (i === 0) {
      if (segment) blocks.push({ type: "text", content: segment });
      continue;
    }
    if (i % 2 === 0) {
      if (segment) blocks.push({ type: "text", content: segment });
    } else {
      const nl = segment.indexOf("\n");
      if (nl === -1) {
        const trimmed = segment.trim();
        blocks.push({ type: "code", language: trimmed || null, content: "" });
      } else {
        const firstLine = segment.slice(0, nl).trim();
        blocks.push({ type: "code", language: firstLine || null, content: segment.slice(nl + 1) });
      }
    }
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Markdown line parsing — MarkdownLineParser port
// ---------------------------------------------------------------------------

export type TableAlignment = "leading" | "center" | "trailing";

export type MarkdownLine =
  | { type: "heading"; level: number; content: string }
  | { type: "paragraph"; content: string }
  | { type: "bullet"; indent: number; content: string }
  | { type: "numbered"; indent: number; number: number; content: string }
  | { type: "quote"; content: string }
  | { type: "table"; headers: string[]; alignments: TableAlignment[]; rows: string[][] }
  | { type: "rule" }
  | { type: "spacer" };

export function parseMarkdown(input: string): MarkdownLine[] {
  const result: MarkdownLine[] = [];
  const rawLines = input.split("\n");
  let i = 0;

  while (i < rawLines.length) {
    const raw = rawLines[i];
    const trimmed = raw.trim();

    if (!trimmed) {
      if (result.length && result[result.length - 1].type !== "spacer") result.push({ type: "spacer" });
      i++;
      continue;
    }

    // Table: a "|" row immediately followed by a valid separator row.
    if (trimmed.includes("|") && i + 1 < rawLines.length) {
      const headerCells = tableCells(trimmed);
      const separatorCells = tableCells(rawLines[i + 1].trim());
      if (headerCells.length >= 2 && headerCells.length === separatorCells.length && isTableSeparatorRow(separatorCells)) {
        const alignments = separatorCells.map(tableAlignment);
        const rows: string[][] = [];
        let j = i + 2;
        while (j < rawLines.length) {
          const rowTrimmed = rawLines[j].trim();
          if (!rowTrimmed || !rowTrimmed.includes("|")) break;
          rows.push(tableCells(rowTrimmed));
          j++;
        }
        result.push({ type: "table", headers: headerCells, alignments, rows });
        i = j;
        continue;
      }
    }

    if (trimmed === "---" || trimmed === "***" || trimmed === "___") {
      result.push({ type: "rule" });
      i++;
      continue;
    }

    const heading = headingMatch(trimmed);
    if (heading) {
      result.push({ type: "heading", level: heading[0], content: heading[1] });
      i++;
      continue;
    }

    if (trimmed.startsWith("> ")) {
      result.push({ type: "quote", content: trimmed.slice(2) });
      i++;
      continue;
    }

    const indent = indentLevel(raw);

    const bullet = bulletContent(trimmed);
    if (bullet !== null) {
      result.push({ type: "bullet", indent, content: bullet });
      i++;
      continue;
    }

    const numbered = numberedContent(trimmed);
    if (numbered) {
      result.push({ type: "numbered", indent, number: numbered[0], content: numbered[1] });
      i++;
      continue;
    }

    result.push({ type: "paragraph", content: trimmed });
    i++;
  }

  if (result.length && result[result.length - 1].type === "spacer") result.pop();
  return result;
}

function headingMatch(line: string): [number, string] | null {
  let level = 0;
  let idx = 0;
  while (idx < line.length && line[idx] === "#" && level < 6) {
    level++;
    idx++;
  }
  if (level === 0 || idx >= line.length || line[idx] !== " ") return null;
  return [level, line.slice(idx + 1).trim()];
}

function bulletContent(line: string): string | null {
  for (const marker of ["- ", "* ", "• "]) {
    if (line.startsWith(marker)) return line.slice(marker.length);
  }
  return null;
}

function numberedContent(line: string): [number, string] | null {
  const m = line.match(/^(\d+)([.)]) (.*)$/s);
  if (!m) return null;
  return [parseInt(m[1], 10), m[3]];
}

function indentLevel(raw: string): number {
  let spaces = 0;
  for (const ch of raw) {
    if (ch === " ") spaces += 1;
    else if (ch === "\t") spaces += 2;
    else break;
  }
  return Math.min(Math.floor(spaces / 2), 3);
}

function tableCells(line: string): string[] {
  let content = line;
  if (content.startsWith("|")) content = content.slice(1);
  if (content.endsWith("|")) content = content.slice(0, -1);
  return content.split("|").map((c) => c.trim());
}

function isTableSeparatorRow(cells: string[]): boolean {
  if (!cells.length) return false;
  return cells.every((cell) => {
    let inner = cell;
    if (inner.startsWith(":")) inner = inner.slice(1);
    if (inner.endsWith(":")) inner = inner.slice(0, -1);
    return inner.length > 0 && /^-+$/.test(inner);
  });
}

function tableAlignment(cell: string): TableAlignment {
  const leading = cell.startsWith(":");
  const trailing = cell.endsWith(":");
  if (leading && trailing) return "center";
  if (trailing) return "trailing";
  return "leading";
}

// ---------------------------------------------------------------------------
// Inline formatting — bold / italic / `code` / [links](url), escaped-safe.
// (The Mac app hands this to AttributedString(markdown:, inlineOnly).)
// ---------------------------------------------------------------------------

const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export function renderInline(raw: string): string {
  let html = escapeHtml(raw);
  // Inline code first so its contents are never re-processed as emphasis.
  html = html.replace(/`([^`]+)`/g, '<code class="inline-code">$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
  html = html.replace(
    /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
    '<a href="$2" target="_blank" rel="noreferrer">$1</a>'
  );
  return html;
}
