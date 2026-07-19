// The input line. Beyond plain typing it carries Claude-Code-style
// affordances: `/` slash-command autocomplete, `@` file-mention
// autocomplete (fed by the project file index), and `!` (run a shell
// command) / `#` (save a note to EAON.md) prefix modes. History is Up/Down;
// backslash-then-Enter inserts a newline (reliable across terminals, unlike
// trying to distinguish Shift+Enter which many emulators don't report).

import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import { theme, PERMISSION_COLORS } from "./theme.js";
import { matchingCommands } from "../commands/index.js";

interface ComposerProps {
  isActive: boolean;
  history: string[];
  onSubmit: (text: string) => void;
  onTogglePermission: () => void;
  onCancel: () => void;
  queryFiles: (query: string) => string[];
  mode: "chat" | "agent" | "claw";
  permissionMode: "sandboxed" | "auto";
}

interface Suggestion {
  label: string;
  hint?: string;
  /** Replaces the active token when chosen. */
  insert: string;
}

/** The whitespace-delimited token the cursor currently sits at the end of —
 * used to detect an in-progress `@mention`. */
function mentionQueryBeforeCursor(buffer: string, cursor: number): { query: string; start: number } | null {
  const upto = buffer.slice(0, cursor);
  const m = upto.match(/(^|\s)@([^\s@]*)$/);
  if (!m) return null;
  const query = m[2];
  return { query, start: cursor - query.length - 1 };
}

export function Composer({ isActive, history, onSubmit, onTogglePermission, onCancel, queryFiles, mode, permissionMode }: ComposerProps): React.ReactElement {
  const [buffer, setBuffer] = useState("");
  const [cursor, setCursor] = useState(0);
  const [historyIndex, setHistoryIndex] = useState<number | null>(null);
  const [suggestionIndex, setSuggestionIndex] = useState(0);

  const showCommandSuggestions = buffer.startsWith("/") && !buffer.includes(" ") && buffer.length > 1;
  const mention = mentionQueryBeforeCursor(buffer, cursor);

  let suggestions: Suggestion[] = [];
  let suggestionKind: "command" | "file" | null = null;
  if (showCommandSuggestions) {
    suggestionKind = "command";
    suggestions = matchingCommands(buffer.slice(1))
      .slice(0, 6)
      .map((c) => ({ label: `/${c.name}`, hint: c.description, insert: `/${c.name} ` }));
  } else if (mention) {
    const files = queryFiles(mention.query);
    if (files.length > 0) {
      suggestionKind = "file";
      suggestions = files.slice(0, 6).map((f) => ({ label: f, insert: `@${f} ` }));
    }
  }

  const applySuggestion = (s: Suggestion) => {
    if (suggestionKind === "file" && mention) {
      const next = buffer.slice(0, mention.start) + s.insert + buffer.slice(cursor);
      setBuffer(next);
      setCursor(mention.start + s.insert.length);
    } else {
      setBuffer(s.insert);
      setCursor(s.insert.length);
    }
    setSuggestionIndex(0);
  };

  useInput(
    (input, key) => {
      if (key.shift && key.tab) {
        onTogglePermission();
        return;
      }
      if (key.escape) {
        if (suggestions.length > 0) {
          setSuggestionIndex(0);
          // let a second Esc reach cancel by clearing the token trigger:
          // simplest is to just drop the suggestion for this keystroke.
          return;
        }
        onCancel();
        return;
      }

      if (suggestions.length > 0) {
        if (key.downArrow) {
          setSuggestionIndex((i) => Math.min(i + 1, suggestions.length - 1));
          return;
        }
        if (key.upArrow) {
          setSuggestionIndex((i) => Math.max(i - 1, 0));
          return;
        }
        if (key.tab) {
          applySuggestion(suggestions[Math.min(suggestionIndex, suggestions.length - 1)]);
          return;
        }
      }

      if (key.return) {
        if (buffer.endsWith("\\")) {
          const next = buffer.slice(0, -1) + "\n";
          setBuffer(next);
          setCursor(next.length);
          return;
        }
        if (buffer.trim().length === 0) return;
        onSubmit(buffer);
        setBuffer("");
        setCursor(0);
        setHistoryIndex(null);
        setSuggestionIndex(0);
        return;
      }

      if (key.upArrow) {
        if (history.length === 0) return;
        const nextIndex = historyIndex === null ? history.length - 1 : Math.max(0, historyIndex - 1);
        setHistoryIndex(nextIndex);
        setBuffer(history[nextIndex] ?? "");
        setCursor((history[nextIndex] ?? "").length);
        return;
      }
      if (key.downArrow) {
        if (historyIndex === null) return;
        const nextIndex = historyIndex + 1;
        if (nextIndex >= history.length) {
          setHistoryIndex(null);
          setBuffer("");
          setCursor(0);
        } else {
          setHistoryIndex(nextIndex);
          setBuffer(history[nextIndex] ?? "");
          setCursor((history[nextIndex] ?? "").length);
        }
        return;
      }
      if (key.leftArrow) {
        setCursor((c) => Math.max(0, c - 1));
        return;
      }
      if (key.rightArrow) {
        setCursor((c) => Math.min(buffer.length, c + 1));
        return;
      }
      if (key.ctrl && input === "u") {
        setBuffer("");
        setCursor(0);
        return;
      }
      if (key.ctrl && input === "a") {
        setCursor(0);
        return;
      }
      if (key.ctrl && input === "e") {
        setCursor(buffer.length);
        return;
      }
      if (key.backspace || key.delete) {
        if (cursor === 0) return;
        setBuffer((b) => b.slice(0, cursor - 1) + b.slice(cursor));
        setCursor((c) => c - 1);
        return;
      }
      if (!key.ctrl && !key.meta && input) {
        setBuffer((b) => b.slice(0, cursor) + input + b.slice(cursor));
        setCursor((c) => c + input.length);
      }
    },
    { isActive }
  );

  const before = buffer.slice(0, cursor);
  const atCursor = cursor < buffer.length ? buffer[cursor] : " ";
  const after = buffer.slice(cursor + 1);
  const isEmpty = buffer.length === 0;

  // The prompt glyph doubles as a mode indicator: `!` for a bash command,
  // `#` for a memory note, otherwise Claude-Code's plain `>`.
  const bash = buffer.startsWith("!");
  const memory = buffer.startsWith("#");
  const glyph = bash ? "!" : memory ? "#" : ">";
  const glyphColor = bash ? theme.warning : memory ? theme.accent : permissionMode === "auto" ? PERMISSION_COLORS.auto : PERMISSION_COLORS.sandboxed;

  const placeholder =
    mode === "chat"
      ? "Ask anything — / for commands"
      : "Describe a task, or ! to run a shell command · @ to add a file · / for commands";

  return (
    <Box flexDirection="column" width="100%">
      <Box borderStyle="round" borderColor={isActive ? glyphColor : theme.muted} paddingX={1} width="100%">
        <Text color={glyphColor} bold>{glyph} </Text>
        <Text>{before}</Text>
        <Text inverse>{atCursor}</Text>
        {isEmpty ? <Text color={theme.muted}>{placeholder}</Text> : <Text>{after}</Text>}
      </Box>

      {bash && isActive && <Text color={theme.muted}>  ! runs a shell command directly and adds the output to the conversation</Text>}
      {memory && isActive && <Text color={theme.muted}>  # saves the rest of this line to EAON.md (this project's memory)</Text>}

      {suggestions.length > 0 && (
        <Box flexDirection="column" marginLeft={2}>
          {suggestions.map((s, idx) => (
            <Text key={s.label} color={idx === suggestionIndex ? theme.accent : theme.muted}>
              {idx === suggestionIndex ? "› " : "  "}
              {suggestionKind === "file" ? "@" : ""}
              {s.label}
              {s.hint ? <Text color={theme.muted}>  {s.hint}</Text> : null}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  );
}
