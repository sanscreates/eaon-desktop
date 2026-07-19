// Faithful TypeScript port of the Mac app's SyntaxHighlighter.swift — the
// same keyword tables and the same single-pass tokenizer (line comments,
// block comments, strings with triple-quote + escape handling, numbers,
// keyword identifiers), so code blocks color identically on both platforms.

export type SyntaxLanguage =
  | "python" | "javascript" | "typescript" | "swift" | "bash" | "json"
  | "go" | "rust" | "ruby" | "php" | "html" | "css" | "c" | "cpp"
  | "java" | "sql" | "yaml" | "plain";

export function detectLanguageFromTag(tag?: string | null): SyntaxLanguage {
  const t = (tag ?? "").toLowerCase().trim();
  if (!t) return "plain";
  switch (t) {
    case "py": case "python": case "python3": return "python";
    case "js": case "javascript": case "jsx": case "mjs": case "cjs": case "node": return "javascript";
    case "ts": case "typescript": case "tsx": return "typescript";
    case "swift": return "swift";
    case "sh": case "bash": case "zsh": case "shell": case "shell-script": case "console": return "bash";
    case "json": case "jsonc": return "json";
    case "go": case "golang": return "go";
    case "rust": case "rs": return "rust";
    case "rb": case "ruby": return "ruby";
    case "php": return "php";
    case "html": case "htm": case "xml": case "svg": return "html";
    case "css": case "scss": case "sass": case "less": return "css";
    case "c": case "h": return "c";
    case "cpp": case "c++": case "cc": case "hpp": case "cxx": return "cpp";
    case "java": case "kotlin": case "kt": return "java";
    case "sql": return "sql";
    case "yaml": case "yml": return "yaml";
    default: return "plain";
  }
}

interface SyntaxRule {
  keywords: Set<string>;
  lineComment: string[];
  blockCommentStart: string | null;
  blockCommentEnd: string | null;
  stringDelimiters: Set<string>;
  supportsNumbers: boolean;
}

const sqlClauses = [
  "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "join",
  "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "as",
  "and", "or", "not", "null", "is", "in", "like", "create", "table", "alter", "drop", "index",
  "primary", "key", "foreign", "references", "default", "unique", "distinct", "union", "all",
  "exists", "case", "when", "then", "end",
];

const RULES: Partial<Record<SyntaxLanguage, SyntaxRule>> = {
  python: {
    keywords: new Set(["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import", "from", "as", "try", "except", "finally", "raise", "with", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "is", "async", "await", "True", "False", "None", "self"]),
    lineComment: ["#"], blockCommentStart: null, blockCommentEnd: null,
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  javascript: {
    keywords: new Set(["function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "var", "let", "const", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "try", "catch", "finally", "throw", "async", "await", "yield", "true", "false", "null", "undefined", "void", "static", "get", "set", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "namespace"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"', "'", "`"]), supportsNumbers: true,
  },
  swift: {
    keywords: new Set(["func", "return", "if", "else", "for", "while", "repeat", "switch", "case", "default", "break", "continue", "var", "let", "class", "struct", "enum", "protocol", "extension", "import", "try", "catch", "throw", "throws", "async", "await", "guard", "in", "is", "as", "nil", "true", "false", "self", "Self", "super", "init", "deinit", "static", "final", "private", "fileprivate", "internal", "public", "open", "mutating", "override", "required", "convenience", "lazy", "weak", "unowned", "where", "some", "any", "typealias", "associatedtype", "inout", "rethrows", "defer"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"']), supportsNumbers: true,
  },
  bash: {
    keywords: new Set(["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "break", "continue", "export", "local", "readonly", "shift", "in", "echo", "exit", "set", "unset", "source", "alias", "true", "false"]),
    lineComment: ["#"], blockCommentStart: null, blockCommentEnd: null,
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  json: {
    keywords: new Set(["true", "false", "null"]),
    lineComment: [], blockCommentStart: null, blockCommentEnd: null,
    stringDelimiters: new Set(['"']), supportsNumbers: true,
  },
  go: {
    keywords: new Set(["func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "var", "const", "type", "struct", "interface", "package", "import", "go", "defer", "chan", "select", "map", "make", "new", "nil", "true", "false", "fallthrough", "goto"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"', "`"]), supportsNumbers: true,
  },
  rust: {
    keywords: new Set(["fn", "return", "if", "else", "for", "while", "loop", "match", "break", "continue", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "pub", "use", "mod", "crate", "self", "Self", "super", "where", "as", "in", "move", "ref", "dyn", "async", "await", "unsafe", "true", "false", "None", "Some", "Ok", "Err"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"']), supportsNumbers: true,
  },
  ruby: {
    keywords: new Set(["def", "end", "return", "if", "elsif", "else", "unless", "for", "while", "until", "case", "when", "break", "next", "class", "module", "require", "require_relative", "include", "attr_accessor", "attr_reader", "attr_writer", "begin", "rescue", "ensure", "raise", "yield", "true", "false", "nil", "self", "do", "then", "in"]),
    lineComment: ["#"], blockCommentStart: null, blockCommentEnd: null,
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  php: {
    keywords: new Set(["function", "return", "if", "else", "elseif", "endif", "for", "foreach", "while", "do", "switch", "case", "default", "break", "continue", "class", "interface", "extends", "implements", "public", "private", "protected", "static", "new", "echo", "print", "require", "require_once", "include", "include_once", "namespace", "use", "try", "catch", "finally", "throw", "true", "false", "null", "this", "array"]),
    lineComment: ["//", "#"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  html: {
    keywords: new Set([]),
    lineComment: [], blockCommentStart: "<!--", blockCommentEnd: "-->",
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: false,
  },
  css: {
    keywords: new Set(["important", "from", "to"]),
    lineComment: [], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  c: {
    keywords: new Set(["int", "float", "double", "char", "void", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "struct", "typedef", "enum", "union", "const", "static", "extern", "sizeof", "include", "define", "ifdef", "ifndef", "endif", "namespace", "class", "public", "private", "protected", "template", "new", "delete", "this", "true", "false", "nullptr", "NULL", "virtual", "override", "using"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
  java: {
    keywords: new Set(["public", "private", "protected", "class", "interface", "extends", "implements", "static", "final", "void", "int", "float", "double", "boolean", "char", "long", "short", "byte", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "super", "try", "catch", "finally", "throw", "throws", "import", "package", "true", "false", "null", "enum", "abstract", "synchronized"]),
    lineComment: ["//"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(['"']), supportsNumbers: true,
  },
  sql: {
    keywords: new Set([...sqlClauses, ...sqlClauses.map((c) => c.toUpperCase())]),
    lineComment: ["--"], blockCommentStart: "/*", blockCommentEnd: "*/",
    stringDelimiters: new Set(["'"]), supportsNumbers: true,
  },
  yaml: {
    keywords: new Set(["true", "false", "null"]),
    lineComment: ["#"], blockCommentStart: null, blockCommentEnd: null,
    stringDelimiters: new Set(['"', "'"]), supportsNumbers: true,
  },
};
RULES.typescript = RULES.javascript;
RULES.cpp = RULES.c;

type TokenKind = "kw" | "str" | "num" | "com";

const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const isLetter = (c: string) => /[a-zA-Z_]/.test(c);
const isWordChar = (c: string) => /[a-zA-Z0-9_]/.test(c);
const isDigit = (c: string) => /[0-9]/.test(c);
const isNumBody = (c: string) => /[0-9a-fA-F._xX]/.test(c);

/** Single forward pass, mirroring SyntaxTokenizer.tokenize — every branch
 * fully consumes what it starts, no backtracking. Returns safe HTML with
 * `<span class="tok-…">` wrapping. */
export function highlight(code: string, language: SyntaxLanguage): string {
  const rule = RULES[language];
  if (!rule) return escapeHtml(code);

  const n = code.length;
  const tokens: Array<{ start: number; end: number; kind: TokenKind }> = [];
  let i = 0;

  const matches = (s: string, at: number) => code.startsWith(s, at);

  while (i < n) {
    const c = code[i];

    const lc = rule.lineComment.find((m) => matches(m, i));
    if (lc) {
      const start = i;
      i += lc.length;
      while (i < n && code[i] !== "\n") i++;
      tokens.push({ start, end: i, kind: "com" });
      continue;
    }

    if (rule.blockCommentStart && rule.blockCommentEnd && matches(rule.blockCommentStart, i)) {
      const start = i;
      i += rule.blockCommentStart.length;
      while (i < n && !matches(rule.blockCommentEnd, i)) i++;
      i = Math.min(i + rule.blockCommentEnd.length, n);
      tokens.push({ start, end: i, kind: "com" });
      continue;
    }

    if (rule.stringDelimiters.has(c)) {
      const start = i;
      const triple = c.repeat(3);
      if (matches(triple, i)) {
        i += 3;
        while (i < n && !matches(triple, i)) i++;
        i = Math.min(i + 3, n);
      } else {
        const quote = c;
        i += 1;
        while (i < n && code[i] !== quote) {
          if (code[i] === "\\" && i + 1 < n) i += 2;
          else i += 1;
        }
        i = Math.min(i + 1, n);
      }
      tokens.push({ start, end: i, kind: "str" });
      continue;
    }

    if (rule.supportsNumbers && isDigit(c)) {
      const start = i;
      while (i < n && isNumBody(code[i])) i++;
      tokens.push({ start, end: i, kind: "num" });
      continue;
    }

    if (isLetter(c)) {
      const start = i;
      while (i < n && isWordChar(code[i])) i++;
      if (rule.keywords.has(code.slice(start, i))) {
        tokens.push({ start, end: i, kind: "kw" });
      }
      continue;
    }

    i++;
  }

  let html = "";
  let cursor = 0;
  for (const t of tokens) {
    if (t.start > cursor) html += escapeHtml(code.slice(cursor, t.start));
    html += `<span class="tok-${t.kind}">${escapeHtml(code.slice(t.start, t.end))}</span>`;
    cursor = t.end;
  }
  if (cursor < n) html += escapeHtml(code.slice(cursor));
  return html;
}
