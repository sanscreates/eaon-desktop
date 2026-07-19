// Renders what write_file/edit_file actually did, Claude-Code-style: real
// line numbers, +/- coloring. write_file shows every line as added (this
// layer only ever has the new content, never the file's prior state, so
// that's an honest framing, not a limitation to hide) — edit_file gets a
// real diff from its own search/replace, independently numbered per side.

import React from "react";
import { Box, Text } from "ink";
import { diffLines } from "diff";
import { theme } from "./theme.js";

function splitTrailingBlank(value: string): string[] {
  const lines = value.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

export function WriteFileDiff({ path, content }: { path: string; content: string }): React.ReactElement {
  const lines = content.length === 0 ? [""] : content.split("\n");
  const capped = lines.slice(0, 400);
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.border} paddingX={1}>
      <Text color={theme.muted}>{path}</Text>
      {capped.map((line, idx) => (
        <Text key={idx}>
          <Text color={theme.muted}>{String(idx + 1).padStart(4)} </Text>
          <Text color={theme.diffAdded}>+ {line.length > 0 ? line : " "}</Text>
        </Text>
      ))}
      {lines.length > capped.length && <Text color={theme.muted}>…and {lines.length - capped.length} more lines</Text>}
    </Box>
  );
}

export function EditFileDiff({ path, search, replace }: { path: string; search: string; replace: string }): React.ReactElement {
  const parts = diffLines(search, replace);
  const rows: Array<{ sign: "-" | "+" | " "; text: string; lineNo: number }> = [];
  let oldNo = 1;
  let newNo = 1;
  for (const part of parts) {
    const lines = splitTrailingBlank(part.value);
    if (part.removed) {
      for (const l of lines) rows.push({ sign: "-", text: l, lineNo: oldNo++ });
    } else if (part.added) {
      for (const l of lines) rows.push({ sign: "+", text: l, lineNo: newNo++ });
    } else {
      for (const l of lines) {
        rows.push({ sign: " ", text: l, lineNo: newNo });
        oldNo++;
        newNo++;
      }
    }
  }
  const capped = rows.slice(0, 400);
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.border} paddingX={1}>
      <Text color={theme.muted}>{path}</Text>
      {capped.map((row, idx) => (
        <Text key={idx}>
          <Text color={theme.muted}>{String(row.lineNo).padStart(4)} </Text>
          <Text color={row.sign === "-" ? theme.diffRemoved : row.sign === "+" ? theme.diffAdded : theme.assistant}>
            {row.sign} {row.text.length > 0 ? row.text : " "}
          </Text>
        </Text>
      ))}
      {rows.length > capped.length && <Text color={theme.muted}>…and {rows.length - capped.length} more lines</Text>}
    </Box>
  );
}
