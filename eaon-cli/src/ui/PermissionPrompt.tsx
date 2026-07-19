// The Sandboxed-mode confirmation gate — blocks the agent loop (via the
// Promise the App bridges through a ref) until the user answers.

import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import { theme } from "./theme.js";
import type { PermissionAnswer } from "../agent/loop.js";

interface Props {
  name: string;
  summary: string;
  detail?: string;
  onAnswer: (answer: PermissionAnswer) => void;
}

const OPTIONS: Array<{ key: string; label: string; answer: PermissionAnswer }> = [
  { key: "y", label: "Yes, allow", answer: "approve" },
  { key: "a", label: "Yes, and don't ask again for this tool this session", answer: "always_this_tool" },
  { key: "n", label: "No", answer: "deny" },
];

export function PermissionPrompt({ name, summary, detail, onAnswer }: Props): React.ReactElement {
  const [index, setIndex] = useState(0);

  useInput((input, key) => {
    const direct = OPTIONS.find((o) => o.key === input.toLowerCase());
    if (direct) {
      onAnswer(direct.answer);
      return;
    }
    if (key.upArrow) {
      setIndex((i) => Math.max(0, i - 1));
      return;
    }
    if (key.downArrow) {
      setIndex((i) => Math.min(OPTIONS.length - 1, i + 1));
      return;
    }
    if (key.return) {
      onAnswer(OPTIONS[index].answer);
      return;
    }
    if (key.escape) {
      onAnswer("deny");
    }
  });

  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.warning} paddingX={1} marginTop={1}>
      <Text bold color={theme.warning}>
        Allow {name}?
      </Text>
      <Text>{summary}</Text>
      {detail && (
        <Box marginTop={1} flexDirection="column">
          {detail.split("\n").slice(0, 20).map((line, i) => (
            <Text key={i} color={theme.muted}>
              {line}
            </Text>
          ))}
          {detail.split("\n").length > 20 && <Text color={theme.muted}>…truncated</Text>}
        </Box>
      )}
      <Box marginTop={1} flexDirection="column">
        {OPTIONS.map((opt, idx) => (
          <Text key={opt.key} color={idx === index ? theme.accent : undefined}>
            {idx === index ? "› " : "  "}[{opt.key}] {opt.label}
          </Text>
        ))}
      </Box>
    </Box>
  );
}
