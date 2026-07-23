// Live generation state — one session per conversation so a background chat
// keeps streaming when the user switches away, plus the pause points where
// an agent turn waits on the user (tool confirmation / ask_user).

import { create } from "zustand";

export interface GenerationSession {
  requestId: number;
  streaming: boolean;
  /** Set by stopGeneration so a multi-step agent turn breaks its loop
   *  instead of only cancelling the current stream. */
  stopped: boolean;
}

/** A tool call paused for the user's go-ahead (Sandboxed mode) — resolved
 *  by the confirmation dialog. */
export interface PendingToolConfirm {
  conversationId: string;
  summary: string;
  detail: string | null;
  resolve: (decision: "once" | "always" | "deny") => void;
}

/** An ask_user question the agent paused on. */
export interface PendingAgentQuestion {
  conversationId: string;
  question: string;
  options: string[];
  resolve: (answer: string) => void;
}

let requestCounter = 1;
export function nextRequestId(): number {
  return requestCounter++;
}

interface GenerationStore {
  sessions: Record<string, GenerationSession>;
  pendingConfirm: PendingToolConfirm | null;
  pendingQuestion: PendingAgentQuestion | null;
  /** Agent mode's Sandboxed(false)/Auto(true) switch — never persisted;
   *  resets to Sandboxed every launch on purpose. */
  agentAutoRun: boolean;
  askingToEnterAuto: boolean;

  begin: (conversationId: string, requestId: number) => void;
  end: (conversationId: string) => void;
  markStopped: (conversationId: string) => void;
  isStreaming: (conversationId: string | null) => boolean;

  setPendingConfirm: (pending: PendingToolConfirm | null) => void;
  setPendingQuestion: (pending: PendingAgentQuestion | null) => void;
  setAgentAutoRun: (on: boolean) => void;
  setAskingToEnterAuto: (asking: boolean) => void;
}

export const useGeneration = create<GenerationStore>((set, get) => ({
  sessions: {},
  pendingConfirm: null,
  pendingQuestion: null,
  agentAutoRun: false,
  askingToEnterAuto: false,

  begin: (conversationId, requestId) =>
    set((s) => ({
      sessions: {
        ...s.sessions,
        [conversationId]: { requestId, streaming: true, stopped: false },
      },
    })),

  end: (conversationId) =>
    set((s) => {
      const sessions = { ...s.sessions };
      delete sessions[conversationId];
      return { sessions };
    }),

  markStopped: (conversationId) =>
    set((s) => {
      const session = s.sessions[conversationId];
      if (!session) return s;
      return {
        sessions: {
          ...s.sessions,
          [conversationId]: { ...session, stopped: true },
        },
      };
    }),

  isStreaming: (conversationId) =>
    conversationId != null && get().sessions[conversationId]?.streaming === true,

  setPendingConfirm: (pendingConfirm) => set({ pendingConfirm }),
  setPendingQuestion: (pendingQuestion) => set({ pendingQuestion }),
  setAgentAutoRun: (agentAutoRun) => set({ agentAutoRun }),
  setAskingToEnterAuto: (askingToEnterAuto) => set({ askingToEnterAuto }),
}));
