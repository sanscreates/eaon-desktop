// A render-level safety net. React (and therefore Ink) has no default
// recovery: if any component throws during render, the whole tree unmounts
// and, in a terminal app, the process is left in a broken state — which is
// exactly the kind of "it just crashed" the user has hit. Wrapping each
// rendered message in this means a malformed message (a bad diff, a regex
// that throws in the markdown inliner, an unexpected shape) degrades to a
// single visible fallback line instead of taking the whole CLI down.

import React from "react";
import { Box, Text } from "ink";
import { theme } from "./theme.js";

interface Props {
  children: React.ReactNode;
  /** Shown (dimmed) in place of whatever failed to render. */
  label?: string;
}

interface State {
  error: Error | null;
}

export class ErrorBoundary extends React.Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  render(): React.ReactNode {
    if (this.state.error) {
      return (
        <Box>
          <Text color={theme.error}>
            ⚠ {this.props.label ?? "This line couldn't be displayed"} ({this.state.error.message})
          </Text>
        </Box>
      );
    }
    return this.props.children;
  }
}
