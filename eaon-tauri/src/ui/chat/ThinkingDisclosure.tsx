// A reasoning model's chain-of-thought, tucked behind a quiet disclosure.
// Collapsed by default; the label pulses while the model is still thinking
// and settles to a past-tense caption once visible content starts.

import { useState } from "react";
import { ChevronRight } from "lucide-react";

export interface ThinkingDisclosureProps {
  reasoning: string;
  /** True while this message is streaming with no visible content yet. */
  thinking: boolean;
}

export default function ThinkingDisclosure({ reasoning, thinking }: ThinkingDisclosureProps) {
  const [open, setOpen] = useState(false);

  return (
    <div className="thinking">
      <button
        className="think-toggle"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
      >
        <span className={"think-chevron" + (open ? " open" : "")} aria-hidden>
          <ChevronRight size={11} strokeWidth={2.4} />
        </span>
        <span className={thinking ? "think-pulse" : ""}>
          {thinking ? "Thinking…" : "Thought for a moment"}
        </span>
      </button>
      {open && (
        <div className="think-body" data-selectable>
          {reasoning}
        </div>
      )}
    </div>
  );
}
