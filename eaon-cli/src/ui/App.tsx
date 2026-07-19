import React, { useCallback, useEffect, useRef, useState } from "react";
import { Box, Text, Static, useApp, useInput } from "ink";
import { randomUUID } from "node:crypto";
import open from "open";
import fs from "node:fs";
import path from "node:path";
import type { EaonMode, ModelEntry, PermissionMode, ToolCallRequest, Turn } from "../types.js";
import { configFile, loadConfig, resolveAquaApiKey, resolveOllamaBaseUrl, saveConfig } from "../config.js";
import { buildCatalog, describeEntry, findModel } from "../providers/registry.js";
import { endpointFor } from "../providers/registry.js";
import { streamChat } from "../providers/chat.js";
import { pullOllamaModel } from "../providers/ollama.js";
import { runAgentTurn, type AgentEvent, type AgentLoopState, type PermissionAnswer } from "../agent/loop.js";
import { systemPromptFor } from "../agent/prompts.js";
import { COMMANDS, parseSlashCommand } from "../commands/index.js";
import { confirmationDetail, confirmationSummary, isKnownTool } from "../tools/index.js";
import { currentTodos, resetTodos } from "../tools/todoTool.js";
import { resetKnownFiles } from "../tools/readTracker.js";
import { listProjectFiles } from "../tools/searchTools.js";
import { runShell } from "../tools/shellTool.js";
import type { PathGuardContext } from "../tools/pathGuard.js";
import { deriveTitle, listSessions, loadSession, newSession, saveSession, type Session } from "../session/store.js";
import { PROJECT_NOTES_FILE, readProjectNotes, runInit } from "../project/init.js";
import { applyDiscoveryToConfig, discoverDesktopCredentials, isLocalDiscoveryAvailable } from "../link/localAuth.js";
import { runLinkServer } from "../link/server.js";
import { platformLabel } from "../platform.js";
import { Composer } from "./Composer.js";
import { PermissionPrompt } from "./PermissionPrompt.js";
import { MessageView } from "./MessageView.js";
import { ErrorBoundary } from "./ErrorBoundary.js";
import { ModelPicker } from "./ModelPicker.js";
import { theme, MODE_LABEL, PERMISSION_COLORS, SPINNER_FRAMES } from "./theme.js";
import { pickRandomQuote } from "./quotes.js";
import type { DisplayMessage } from "./types.js";

export interface AppProps {
  version: string;
  initialMode: EaonMode;
  initialModelKey: string | null;
  projectRoot: string;
  startInAuto: boolean;
}

function turnsToDisplayMessages(turns: Turn[]): DisplayMessage[] {
  const out: DisplayMessage[] = [];
  for (const t of turns) {
    if (t.role === "system") continue;
    if (t.role === "user") {
      out.push({ id: randomUUID(), role: "user", text: t.content });
      continue;
    }
    if (t.role === "assistant") {
      if (t.content.trim().length > 0) {
        out.push({ id: randomUUID(), role: "assistant", text: t.content, reasoning: "", streaming: false });
      }
      for (const call of t.toolCalls ?? []) {
        out.push(...displayForToolCall(call, turns));
      }
    }
  }
  return out;
}

function displayForToolCall(call: ToolCallRequest, turns: Turn[]): DisplayMessage[] {
  let args: Record<string, unknown> = {};
  try {
    args = call.arguments.trim().length > 0 ? JSON.parse(call.arguments) : {};
  } catch {
    // fall through with empty args — resumed display degrades gracefully
  }
  const toolName = call.name;
  const summary = isKnownTool(toolName) ? confirmationSummary(toolName, args) : toolName;
  const detail = isKnownTool(toolName) ? confirmationDetail(toolName, args) : undefined;
  const resultTurn = turns.find((rt) => rt.role === "tool" && rt.toolCallId === call.id);
  return [
    {
      id: randomUUID(),
      role: "tool",
      name: call.name,
      summary,
      detail,
      args,
      pending: !resultTurn,
      callId: call.id,
      result: resultTurn ? { isError: resultTurn.isError === true, text: resultTurn.content } : undefined,
    },
  ];
}

function resolveModelQuery(catalog: ModelEntry[], query: string): ModelEntry[] {
  const lower = query.toLowerCase();
  const exact = catalog.filter((m) => m.key.toLowerCase() === lower || m.requestId.toLowerCase() === lower);
  if (exact.length > 0) return exact;
  return catalog.filter(
    (m) => m.key.toLowerCase().includes(lower) || m.display.toLowerCase().includes(lower) || m.requestId.toLowerCase().includes(lower)
  );
}

function formatCatalog(catalog: ModelEntry[], current: ModelEntry | null): string {
  if (catalog.length === 0) {
    return "No models available yet.\n\n- Cloud: run /link to import your Aqua key and providers from Eaon Desktop\n- Local: install Ollama (ollama.com) and pull a model, e.g. /pull qwen3.6\n- Aqua: or set EAON_AQUA_API_KEY directly\n- BYOK: or add a custom provider to ~/.eaon/cli/config.json (customProviders)";
  }
  const lines = catalog.map((m) => `${m.key === current?.key ? "› " : "  "}${m.key}  —  ${describeEntry(m)}`);
  return ["Available models:", ...lines, "", "Switch with /model <name>."].join("\n");
}

function buildHelpMarkdown(): string {
  const rows = COMMANDS.map((c) => `- **/${c.name}**${c.usage ? ` ${c.usage.replace(`/${c.name}`, "").trim()}` : ""} — ${c.description}`);
  return [
    "## Eaon CLI — Help",
    "",
    "### Commands",
    ...rows,
    "",
    "### Input",
    "- **!**`command` — run a shell command directly and add its output to the conversation",
    "- **@**`path` — reference a file (autocompletes); its contents are sent to the model with your message",
    "- **#**`note` — save a note to this project's EAON.md memory",
    "- **/**`name` — a slash command (autocompletes)",
    "",
    "### Keyboard",
    "- **Shift+Tab** — toggle Sandboxed / Auto",
    "- **Esc** — cancel the current generation",
    "- **Tab** — accept the highlighted autocomplete suggestion",
    "- **Up / Down** — command history (or move within a picker/suggestions)",
    "- **Ctrl+C** twice — exit",
    "- **\\\\** then Enter — insert a newline in the composer",
  ].join("\n");
}

function buildStatusMarkdown(opts: {
  mode: EaonMode;
  permissionMode: PermissionMode;
  model: ModelEntry | null;
  config: import("../types.js").EaonConfig;
  catalog: ModelEntry[];
  projectRoot: string;
  turns: Turn[];
}): string {
  const { mode, permissionMode, model, config, catalog, projectRoot, turns } = opts;
  const aquaCount = catalog.filter((m) => m.provider.kind === "aqua").length;
  const ollamaCount = catalog.filter((m) => m.provider.kind === "ollama").length;
  const customCount = catalog.filter((m) => m.provider.kind === "custom").length;
  const userTurns = turns.filter((t) => t.role === "user").length;
  const toolCalls = turns.filter((t) => t.role === "tool").length;
  const chars = turns.filter((t) => t.role === "assistant").reduce((sum, t) => sum + t.content.length, 0);

  return [
    "## Status",
    "",
    `**Mode:** ${MODE_LABEL[mode]} · **Permission:** ${permissionMode === "auto" ? "Auto" : "Sandboxed"}`,
    `**Model:** ${model ? describeEntry(model) : "none selected"}`,
    `**Project:** ${projectRoot}`,
    `**Platform:** ${platformLabel()}`,
    "",
    "### Providers",
    `- Aqua: ${resolveAquaApiKey(config) ? `configured, ${aquaCount} model(s)` : "not configured — try /link"}`,
    `- Ollama: ${ollamaCount > 0 ? `${ollamaCount} model(s) found` : "not reachable / no models"}`,
    `- BYOK: ${config.customProviders.length} provider(s) configured, ${customCount} model(s)`,
    "",
    "### This session",
    `- ${userTurns} message${userTurns === 1 ? "" : "s"} sent`,
    `- ${toolCalls} tool call${toolCalls === 1 ? "" : "s"} executed`,
    `- ~${chars.toLocaleString()} character${chars === 1 ? "" : "s"} generated`,
  ].join("\n");
}

/** ~4 chars/token — the same rough heuristic the desktop app's context
 * badge uses. Honest about being approximate everywhere it's shown. */
function estimateTokens(turns: Turn[]): number {
  let chars = 0;
  for (const t of turns) chars += t.content.length + (t.reasoning?.length ?? 0) + (t.toolCalls ? JSON.stringify(t.toolCalls).length : 0);
  return Math.round(chars / 4);
}

function buildContextMarkdown(turns: Turn[]): string {
  const byRole = (role: string) => turns.filter((t) => t.role === role);
  const tokensOf = (ts: Turn[]) => estimateTokens(ts).toLocaleString();
  return [
    "## Context usage (approximate)",
    "",
    `**Total:** ~${estimateTokens(turns).toLocaleString()} tokens across ${turns.length} turns`,
    "",
    `- System prompt: ~${tokensOf(byRole("system"))} tokens`,
    `- Your messages: ~${tokensOf(byRole("user"))} tokens (${byRole("user").length})`,
    `- Assistant replies: ~${tokensOf(byRole("assistant"))} tokens (${byRole("assistant").length})`,
    `- Tool results: ~${tokensOf(byRole("tool"))} tokens (${byRole("tool").length})`,
    "",
    "Estimated at ~4 characters per token. When this gets large, /compact summarizes the conversation and keeps going with a much smaller context.",
  ].join("\n");
}

function redactKey(key: string): string {
  if (!key) return "(not set)";
  return key.length <= 8 ? "••••" : `${key.slice(0, 4)}…${key.slice(-4)} (redacted)`;
}

function transcriptMarkdown(turns: Turn[], modelLabel: string): string {
  const lines: string[] = [`# Eaon session`, "", `_Model: ${modelLabel} · Exported ${new Date().toLocaleString()}_`, ""];
  for (const t of turns) {
    if (t.role === "system") continue;
    if (t.role === "user") lines.push(`## You`, "", t.content, "");
    else if (t.role === "assistant") {
      if (t.content.trim()) lines.push(`## Eaon`, "", t.content, "");
      for (const call of t.toolCalls ?? []) lines.push(`> tool call: \`${call.name}\``, "");
    } else if (t.role === "tool") {
      const body = t.content.length > 2000 ? t.content.slice(0, 2000) + "\n…(truncated)" : t.content;
      lines.push(`<details><summary>tool result: ${t.name ?? "?"}${t.isError ? " (error)" : ""}</summary>`, "", "```", body, "```", "", "</details>", "");
    }
  }
  return lines.join("\n");
}

const COMPACT_INSTRUCTION = `Summarize this coding session so a fresh instance of you can seamlessly continue the work. Include: (1) what the user is trying to accomplish overall, (2) what has actually been DONE so far — files created/changed (with paths) and what's in them, commands run and their real outcomes, (3) anything learned about the project/environment that isn't obvious (layout, conventions, gotchas hit), and (4) exactly where things stand now and what the next step was going to be. Be specific and factual — only include things that actually happened in this conversation. Reply with ONLY the summary text.`;

/** The persistent whole-turn status line under the composer — spinner +
 * elapsed seconds for as long as the agent is working (streaming, running
 * tools, everything), same as Claude Code's working indicator. Entirely
 * self-contained state (own interval) so it costs the rest of the tree
 * nothing; it mounts when a turn starts and unmounts when it ends, which
 * also makes the elapsed time per-turn for free. */
function GenerationStatus(): React.ReactElement {
  const [frame, setFrame] = useState(0);
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    const start = Date.now();
    const id = setInterval(() => {
      setFrame((f) => (f + 1) % SPINNER_FRAMES.length);
      setSeconds(Math.floor((Date.now() - start) / 1000));
    }, 120);
    return () => clearInterval(id);
  }, []);
  return (
    <Text color={theme.muted}>
      {"  "}
      <Text color={theme.accent}>{SPINNER_FRAMES[frame]}</Text> working… {seconds}s · esc to interrupt · type + enter to redirect
    </Text>
  );
}

function AutoModeConfirm({ onAnswer }: { onAnswer: (yes: boolean) => void }): React.ReactElement {
  useInput((input, key) => {
    if (input.toLowerCase() === "y" || key.return) onAnswer(true);
    else if (input.toLowerCase() === "n" || key.escape) onAnswer(false);
  });
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={PERMISSION_COLORS.auto} paddingX={1} marginTop={1}>
      <Text bold color={PERMISSION_COLORS.auto}>
        Switch to Auto mode?
      </Text>
      <Text color={theme.muted}>Tool calls will run immediately, with no confirmation prompt. Press Y to confirm, N to cancel.</Text>
    </Box>
  );
}

export function App({ version, initialMode, initialModelKey, projectRoot, startInAuto }: AppProps): React.ReactElement {
  const { exit } = useApp();
  const [config, setConfig] = useState(() => loadConfig());
  const [mode, setMode] = useState<EaonMode>(initialMode);
  const [permissionMode, setPermissionMode] = useState<PermissionMode>(startInAuto ? "auto" : "sandboxed");
  const [confirmingAuto, setConfirmingAuto] = useState(false);
  const [catalog, setCatalog] = useState<ModelEntry[]>([]);
  const [catalogLoading, setCatalogLoading] = useState(true);
  const [model, setModel] = useState<ModelEntry | null>(null);
  const [messages, setMessages] = useState<DisplayMessage[]>([]);
  const [isGenerating, setIsGenerating] = useState(false);
  const [pendingPermission, setPendingPermission] = useState<{ name: string; summary: string; detail?: string } | null>(null);
  const [submitHistory, setSubmitHistory] = useState<string[]>([]);
  const [statusText, setStatusText] = useState<string | null>(null);
  const [modelPickerOpen, setModelPickerOpen] = useState(false);
  // Bumped whenever a todo_write result lands so the pinned checklist
  // re-renders — the list itself lives in the tool module (per-process).
  const [todoVersion, setTodoVersion] = useState(0);
  // Bumped on /clear, /resume, /compact — anything that wholesale-replaces
  // `messages` instead of appending to it. Passed as <Static>'s `key` so
  // React remounts it (resetting its internal "already rendered" index)
  // instead of leaving it desynced: Static only ever renders
  // items.slice(previouslySeenCount), so swapping in a same-or-shorter
  // array without a remount silently drops content (a resumed session's
  // transcript, or /compact's own summary message, would never appear).
  const [historyEpoch, setHistoryEpoch] = useState(0);
  // Live approximate size of the conversation for the status bar — updated
  // when a turn finishes rather than per-token (cheap and steady).
  const [contextTokens, setContextTokens] = useState(0);

  const turnsRef = useRef<Turn[]>([]);
  const permissionResolveRef = useRef<((a: PermissionAnswer) => void) | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const alwaysAllowRef = useRef<Set<string>>(new Set());
  const sessionIdRef = useRef<string>(randomUUID());
  const lastCtrlCRef = useRef<number>(0);
  /** Set only when the user submits new text WHILE a turn is generating —
   * runLoop's `finally` picks this up once the aborted turn has actually
   * finished unwinding and starts the next one, so an interrupt always
   * fully stops the old turn before the new one begins (never two turns
   * racing on the same `turnsRef`). */
  const interruptResubmitRef = useRef<string | null>(null);
  /** Built once, lazily, on first `@`-mention keystroke and cached for the
   * session — a full re-walk per keystroke would make typing `@` laggy on a
   * big tree. Files created mid-session won't appear until relaunch; a fair
   * trade for instant autocomplete. */
  const fileIndexRef = useRef<string[] | null>(null);

  const pushSystem = useCallback((text: string, tone: "info" | "error" | "success" = "info") => {
    setMessages((prev) => [...prev, { id: randomUUID(), role: "system", text, tone }]);
  }, []);

  // Renders as real Markdown (headers, bold, lists) via the same renderer
  // assistant replies use — reused deliberately for /help and /status
  // instead of a new component, since MessageView never prints a "model"
  // attribution on an assistant row, so this can't be mistaken for
  // something the model actually said.
  const pushMarkdown = useCallback((text: string) => {
    setMessages((prev) => [...prev, { id: randomUUID(), role: "assistant", text, reasoning: "", streaming: false }]);
  }, []);

  const refreshCatalog = useCallback(async () => {
    const result = await buildCatalog(config);
    setCatalog(result.models);
    return result;
  }, [config]);

  // Picked once, at mount, not on every render — "a new quote each time you
  // open it" means once per launch, not once per keystroke.
  const [launchQuote] = useState(() => pickRandomQuote());

  // Startup: build the catalog, pick a model, show the welcome banner.
  useEffect(() => {
    (async () => {
      const result = await refreshCatalog();
      setCatalogLoading(false);
      let chosen: ModelEntry | undefined;
      if (initialModelKey) chosen = findModel(result.models, initialModelKey);
      if (!chosen && config.selectedModelKey) chosen = findModel(result.models, config.selectedModelKey);
      if (!chosen) chosen = result.models[0];
      if (chosen) setModel(chosen);

      setMessages((prev) => [
        ...prev,
        {
          id: randomUUID(),
          role: "banner",
          version,
          quote: launchQuote,
          mode,
          modelLabel: chosen ? describeEntry(chosen) : "no model selected — try /models",
          projectRoot,
          recentSessions: listSessions(4),
        },
      ]);

      const notes = readProjectNotes(projectRoot);
      if (result.aquaError) pushSystem(`Aqua models unavailable: ${result.aquaError}`, "error");
      if (notes) pushSystem("Loaded EAON.md for project context.", "info");
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const buildLoopState = useCallback((): AgentLoopState => {
    const notes = readProjectNotes(projectRoot);
    const extra = [config.customInstructions, notes].filter((s): s is string => !!s && s.trim().length > 0).join("\n\n---\n\n");
    const systemContent = systemPromptFor(mode, projectRoot, permissionMode, extra);
    if (turnsRef.current.length === 0) turnsRef.current.push({ role: "system", content: systemContent });
    else turnsRef.current[0] = { role: "system", content: systemContent };
    return {
      mode,
      permissionMode,
      model: model as ModelEntry,
      config,
      pathCtx: { projectRoot } as PathGuardContext,
      turns: turnsRef.current,
      alwaysAllow: alwaysAllowRef.current,
    };
  }, [mode, permissionMode, model, config, projectRoot]);

  const persistCurrentSession = useCallback(() => {
    const session: Session = {
      id: sessionIdRef.current,
      title: deriveTitle(turnsRef.current),
      mode,
      modelKey: model?.key ?? null,
      projectRoot,
      turns: turnsRef.current,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    try {
      saveSession(session);
    } catch {
      // best-effort — never let a save failure interrupt the conversation
    }
  }, [mode, model, projectRoot]);

  const runLoop = useCallback(async () => {
    if (!model) {
      pushSystem("No model selected — try /models.", "error");
      return;
    }
    setIsGenerating(true);
    const controller = new AbortController();
    abortRef.current = controller;

    const assistantId = randomUUID();
    setMessages((prev) => [...prev, { id: assistantId, role: "assistant", text: "", reasoning: "", streaming: true }]);

    // Streaming a local model can produce dozens of tokens a second, and
    // pushing a full setState (and the Markdown re-parse/re-highlight it
    // triggers) on EVERY one is what actually made the terminal feel
    // laggy — not the model, the render loop. Deltas accumulate here and
    // flush to state on a fixed ~40ms cadence (25fps: smooth to watch,
    // cheap to render) instead of once per token.
    let pendingText = "";
    let pendingReasoning = "";
    let flushTimer: ReturnType<typeof setTimeout> | null = null;
    const flush = () => {
      flushTimer = null;
      if (pendingText.length === 0 && pendingReasoning.length === 0) return;
      const text = pendingText;
      const reasoning = pendingReasoning;
      pendingText = "";
      pendingReasoning = "";
      setMessages((prev) =>
        prev.map((m) => (m.id === assistantId && m.role === "assistant" ? { ...m, text: m.text + text, reasoning: m.reasoning + reasoning } : m))
      );
    };
    const scheduleFlush = () => {
      if (flushTimer === null) flushTimer = setTimeout(flush, 40);
    };

    const loopState = buildLoopState();
    const gen = runAgentTurn(loopState, { signal: controller.signal });
    let sendValue: PermissionAnswer | undefined;

    try {
      while (true) {
        let step: IteratorResult<AgentEvent, void>;
        try {
          step = await gen.next(sendValue);
        } catch (e) {
          pushSystem(`Unexpected error: ${e instanceof Error ? e.message : String(e)}`, "error");
          break;
        }
        sendValue = undefined;
        if (step.done) break;
        const event = step.value;

        if (event.type === "content_delta") {
          pendingText += event.text;
          scheduleFlush();
        } else if (event.type === "reasoning_delta") {
          pendingReasoning += event.text;
          scheduleFlush();
        } else if (event.type === "turn_end" || event.type === "tool_call_requested" || event.type === "permission_request") {
          // Flush immediately before anything that renders alongside the
          // streamed text (a tool row, a permission prompt) — otherwise
          // the buffered tail of the reply would appear to arrive AFTER
          // the tool call that logically followed it.
          if (flushTimer !== null) {
            clearTimeout(flushTimer);
            flush();
          }
        }

        if (event.type === "tool_call_requested") {
          setMessages((prev) => [
            ...prev,
            { id: randomUUID(), role: "tool", name: event.name, summary: event.summary, detail: event.detail, args: event.args, pending: true, callId: event.callId },
          ]);
        } else if (event.type === "permission_request") {
          sendValue = await new Promise<PermissionAnswer>((resolve) => {
            permissionResolveRef.current = resolve;
            setPendingPermission({ name: event.name, summary: event.summary, detail: event.detail });
          });
          setPendingPermission(null);
          permissionResolveRef.current = null;
        } else if (event.type === "tool_result") {
          if (event.name === "todo_write") setTodoVersion((v) => v + 1);
          setMessages((prev) => {
            // Match by the loop's call id — exact, so two same-named calls
            // in one turn can never fill each other's rows. The name-based
            // fallback only covers a row created before callId existed.
            let idx = prev.findIndex((m) => m.role === "tool" && m.pending && m.callId === event.callId);
            if (idx === -1) idx = prev.map((m) => m.role === "tool" && m.pending && m.name === event.name).lastIndexOf(true);
            if (idx === -1) return prev;
            const copy = [...prev];
            const row = copy[idx];
            if (row.role === "tool") copy[idx] = { ...row, pending: false, result: { isError: event.isError, text: event.text } };
            return copy;
          });
        } else if (event.type === "step_error") {
          pushSystem(event.message, "error");
        } else if (event.type === "loop_stopped") {
          pushSystem(event.reason, "error");
        }
      }
    } catch (e) {
      // Defense in depth: gen.next() above already has its own inner
      // try/catch, but nothing else in this loop did — and runLoop always
      // runs fire-and-forget (`void runLoop()`), so anything that escaped
      // here would otherwise be an unhandled rejection, which crashes the
      // whole process by default. Surface it instead of taking the TUI down.
      pushSystem(`Unexpected error: ${e instanceof Error ? e.message : String(e)}`, "error");
    } finally {
      if (flushTimer !== null) clearTimeout(flushTimer);
      flush();
      setIsGenerating(false);
      abortRef.current = null;
      setMessages((prev) => prev.map((m) => (m.id === assistantId && m.role === "assistant" ? { ...m, streaming: false } : m)));
      setContextTokens(estimateTokens(turnsRef.current));
      persistCurrentSession();

      // An interrupt arrived mid-turn (see handleSubmit) — the old turn
      // has now genuinely finished unwinding (we're past the abort), so
      // it's safe to start the redirected one.
      const resubmit = interruptResubmitRef.current;
      if (resubmit !== null) {
        interruptResubmitRef.current = null;
        setMessages((prev) => [...prev, { id: randomUUID(), role: "user", text: resubmit }]);
        turnsRef.current.push({ role: "user", content: resubmit });
        void runLoop().catch((e) => pushSystem(`Unexpected error: ${e instanceof Error ? e.message : String(e)}`, "error"));
      }
    }
  }, [model, buildLoopState, pushSystem, persistCurrentSession]);

  const handlePull = useCallback(
    async (name: string) => {
      pushSystem(`Pulling ${name}…`, "info");
      let lastShown = -1;
      for await (const ev of pullOllamaModel(resolveOllamaBaseUrl(config), name)) {
        if (ev.type === "progress") {
          if (ev.total > 0) {
            const pct = Math.floor((ev.completed / ev.total) * 100);
            if (pct !== lastShown) {
              lastShown = pct;
              setStatusText(`${ev.status} — ${pct}%`);
            }
          } else if (ev.status) {
            setStatusText(ev.status);
          }
        } else if (ev.type === "error") {
          setStatusText(null);
          pushSystem(`Pull failed: ${ev.message}`, "error");
          return;
        } else if (ev.type === "done") {
          setStatusText(null);
          pushSystem(`${name} is ready.`, "success");
          await refreshCatalog();
        }
      }
    },
    [config, pushSystem, refreshCatalog]
  );

  const handleLink = useCallback(async () => {
    if (!isLocalDiscoveryAvailable()) {
      pushSystem("/link reads Eaon Desktop's saved credentials from macOS UserDefaults, so it only works on a Mac with Eaon Desktop installed.", "error");
      return;
    }
    pushSystem("Looking for Eaon Desktop's saved credentials on this Mac…");
    const discovery = discoverDesktopCredentials();
    if (!discovery.domain) {
      pushSystem("Couldn't find any saved Eaon Desktop credentials on this Mac — open Eaon Desktop and add an Aqua key or a custom provider first, then try /link again.", "error");
      return;
    }

    // The server-startup/network section below has real (if rare) failure
    // modes (a bind error rejecting `url`, etc.) — handleLink runs fire-
    // and-forget (`void handleCommand(...)` in handleSubmit), so anything
    // that escaped uncaught here would crash the whole process rather than
    // just failing this one command.
    try {
      const { url, result } = runLinkServer(discovery);
      const linkUrl = await url;
      pushSystem(`Opening your browser to confirm: ${linkUrl}`);
      try {
        await open(linkUrl);
      } catch {
        pushSystem(`Couldn't open a browser automatically — open this URL yourself: ${linkUrl}`, "error");
      }

      const outcome = await result;
      if (outcome.timedOut) {
        pushSystem("Link expired after 3 minutes with no response — run /link again.", "error");
        return;
      }
      if (!outcome.approved) {
        pushSystem("Cancelled — nothing was imported.", "info");
        return;
      }

      const selection = { includeAquaKey: outcome.includeAquaKey, selectedProviderIds: outcome.selectedProviderIds };
      if (!selection.includeAquaKey && selection.selectedProviderIds.length === 0) {
        pushSystem("Nothing was checked on the page, so nothing was imported.", "info");
        return;
      }

      const nextConfig = applyDiscoveryToConfig(config, discovery, selection);
      setConfig(nextConfig);
      saveConfig(nextConfig);
      // NOT refreshCatalog() here: that callback closes over `config` from
      // whichever render created it, and setConfig above hasn't landed yet in
      // THIS still-running function — calling it would rebuild the catalog
      // from the stale, pre-link config (no Aqua key yet), so /model would
      // show only Ollama models right after a successful link even though
      // "Linked ✓" already printed. Building straight from the real,
      // just-computed `nextConfig` sidesteps the stale closure entirely.
      setCatalogLoading(true);
      const catalogResult = await buildCatalog(nextConfig);
      setCatalog(catalogResult.models);
      setCatalogLoading(false);
      if (catalogResult.aquaError) pushSystem(`Aqua models unavailable after linking: ${catalogResult.aquaError}`, "error");

      const importedProviders = discovery.customProviders.filter((p) => selection.selectedProviderIds.includes(p.id));
      const aquaModelCount = catalogResult.models.filter((m) => m.provider.kind === "aqua").length;
      const parts: string[] = [];
      if (selection.includeAquaKey) parts.push(`Aqua API key (${aquaModelCount} model${aquaModelCount === 1 ? "" : "s"})`);
      if (importedProviders.length > 0) {
        parts.push(
          `${importedProviders.length} of ${discovery.customProviders.length} custom provider${discovery.customProviders.length === 1 ? "" : "s"} (${importedProviders.map((p) => p.displayName).join(", ")})`
        );
      }
      const skippedNote = discovery.skippedUnrecognizedFormat > 0 ? ` (skipped ${discovery.skippedUnrecognizedFormat} in an unrecognized format)` : "";
      pushSystem(`Linked ✓ — imported ${parts.join(" and ")}${skippedNote}. Try /model to pick a cloud model.`, "success");
    } catch (e) {
      setCatalogLoading(false);
      pushSystem(`/link failed: ${e instanceof Error ? e.message : String(e)}`, "error");
    }
  }, [config, pushSystem]);

  const handleCompact = useCallback(async () => {
    const nonSystem = turnsRef.current.filter((t) => t.role !== "system");
    if (nonSystem.length < 2) {
      pushSystem("Nothing to compact yet — the conversation is still small.");
      return;
    }
    if (!model) {
      pushSystem("No model selected — /compact needs one to write the summary.", "error");
      return;
    }
    const before = estimateTokens(turnsRef.current);
    setStatusText("Compacting conversation…");
    try {
      const { baseUrl, apiKey, format } = endpointFor(model, config);
      // The summarizer sees the real conversation plus one closing
      // instruction — no tools, no streaming UI, just accumulate the text.
      const summaryTurns: Turn[] = [...turnsRef.current, { role: "user", content: COMPACT_INSTRUCTION }];
      let summary = "";
      let errorMessage: string | null = null;
      for await (const ev of streamChat({ baseUrl, apiKey, model: model.requestId, turns: summaryTurns, format })) {
        if (ev.type === "token") summary += ev.text;
        else if (ev.type === "error") errorMessage = ev.message;
      }
      if (errorMessage || summary.trim().length === 0) {
        pushSystem(`Compact failed: ${errorMessage ?? "the model returned nothing"}. The conversation is unchanged.`, "error");
        return;
      }
      turnsRef.current = [
        { role: "user", content: `[Summary of the conversation so far — compacted to save context]\n\n${summary.trim()}` },
      ];
      const after = estimateTokens(turnsRef.current);
      setContextTokens(after);
      setMessages([]);
      setHistoryEpoch((e) => e + 1);
      pushMarkdown(`## Conversation compacted\n\n~${before.toLocaleString()} → ~${after.toLocaleString()} tokens. The summary below is what the model now remembers:\n\n${summary.trim()}`);
      persistCurrentSession();
    } catch (e) {
      // Belt and suspenders: endpointFor/streamChat don't throw today, but
      // handleCompact runs fire-and-forget (`void handleCommand(...)`), so
      // if that ever changes, an escaping error should end up as a normal
      // message instead of crashing the whole session.
      pushSystem(`Compact failed: ${e instanceof Error ? e.message : String(e)}. The conversation is unchanged.`, "error");
    } finally {
      setStatusText(null);
    }
  }, [model, config, pushSystem, pushMarkdown, persistCurrentSession]);

  const handleCommand = useCallback(
    async (name: string, args: string) => {
      const parsed = parseSlashCommand(`/${name} ${args}`);
      if (!parsed) return;
      const outcome = parsed.command.run(parsed.args);

      switch (outcome.kind) {
        case "message":
          pushSystem(outcome.text, "info");
          return;
        case "error":
          pushSystem(outcome.text, "error");
          return;
        case "set_mode":
          setMode(outcome.mode);
          pushSystem(`Switched to ${MODE_LABEL[outcome.mode]} mode.`, "success");
          return;
        case "set_permission":
          setPermissionMode(outcome.mode);
          pushSystem(`Permission mode: ${outcome.mode}.`, "success");
          return;
        case "set_model": {
          const matches = resolveModelQuery(catalog, outcome.query);
          if (matches.length === 0) {
            pushSystem(`No model matches "${outcome.query}". Try /models to see what's available.`, "error");
          } else if (matches.length > 1 && !matches.some((m) => m.key.toLowerCase() === outcome.query.toLowerCase())) {
            pushSystem(`"${outcome.query}" matches more than one model:\n${matches.map((m) => `  ${m.key}`).join("\n")}\nBe more specific.`, "error");
          } else {
            const chosen = matches[0];
            setModel(chosen);
            const nextConfig = { ...config, selectedModelKey: chosen.key };
            setConfig(nextConfig);
            saveConfig(nextConfig);
            pushSystem(`Switched to ${describeEntry(chosen)}.`, "success");
          }
          return;
        }
        case "open_model_picker":
          setModelPickerOpen(true);
          return;
        case "list_models":
          pushSystem(formatCatalog(catalog, model));
          return;
        case "pull_model":
          await handlePull(outcome.name);
          return;
        case "link":
          await handleLink();
          return;
        case "help":
          pushMarkdown(buildHelpMarkdown());
          return;
        case "status":
          pushMarkdown(buildStatusMarkdown({ mode, permissionMode, model, config, catalog, projectRoot, turns: turnsRef.current }));
          return;
        case "init_project": {
          try {
            const result = await runInit(projectRoot);
            pushSystem(`Wrote ${result.file}\n${result.summary}`, "success");
          } catch (e) {
            pushSystem(`Couldn't write EAON.md: ${e instanceof Error ? e.message : String(e)}`, "error");
          }
          return;
        }
        case "clear":
          turnsRef.current = [];
          sessionIdRef.current = randomUUID();
          resetTodos();
          resetKnownFiles();
          fileIndexRef.current = null;
          setTodoVersion((v) => v + 1);
          setContextTokens(0);
          setMessages([]);
          setHistoryEpoch((e) => e + 1);
          pushSystem("Started a new session.", "info");
          return;
        case "resume": {
          if (!outcome.sessionId) {
            const sessions = listSessions();
            if (sessions.length === 0) {
              pushSystem("No saved sessions yet.");
            } else {
              const lines = sessions.map((s) => `  ${s.id.slice(0, 8)}  ${MODE_LABEL[s.mode]}  ${new Date(s.updatedAt).toLocaleString()}  ${s.title}`);
              pushSystem(["Recent sessions (/resume <id>):", ...lines].join("\n"));
            }
            return;
          }
          const full = listSessions(200).find((s) => s.id.startsWith(outcome.sessionId!));
          const loaded = full ? loadSession(full.id) : null;
          if (!loaded) {
            pushSystem(`No session matching "${outcome.sessionId}".`, "error");
            return;
          }
          turnsRef.current = loaded.turns;
          sessionIdRef.current = loaded.id;
          resetKnownFiles();
          setMode(loaded.mode);
          if (loaded.modelKey) {
            const found = findModel(catalog, loaded.modelKey);
            if (found) setModel(found);
          }
          setMessages(turnsToDisplayMessages(loaded.turns));
          setHistoryEpoch((e) => e + 1);
          pushSystem(`Resumed "${loaded.title}".`, "success");
          return;
        }
        case "cost": {
          const userTurns = turnsRef.current.filter((t) => t.role === "user").length;
          const assistantChars = turnsRef.current.filter((t) => t.role === "assistant").reduce((sum, t) => sum + t.content.length, 0);
          pushSystem(`This session: ${userTurns} message${userTurns === 1 ? "" : "s"} sent, ~${assistantChars.toLocaleString()} characters generated. (Approximate — Eaon CLI doesn't have per-provider pricing data to convert this to cost.)`);
          return;
        }
        case "compact":
          await handleCompact();
          return;
        case "context":
          pushMarkdown(buildContextMarkdown(turnsRef.current));
          return;
        case "doctor": {
          const checks: string[] = [];
          checks.push(`- Node: ${process.version} ✓`);
          checks.push(`- Platform: ${platformLabel()}`);
          const ollamaUrl = resolveOllamaBaseUrl(config);
          try {
            const res = await fetch(`${ollamaUrl}/api/tags`, { signal: AbortSignal.timeout(3000) });
            const data = (await res.json()) as { models?: unknown[] };
            checks.push(`- Ollama at ${ollamaUrl}: reachable, ${data.models?.length ?? 0} model(s) ✓`);
          } catch {
            checks.push(`- Ollama at ${ollamaUrl}: not reachable — install from ollama.com for local models`);
          }
          checks.push(`- Aqua API key: ${resolveAquaApiKey(config) ? "configured ✓" : "not set — /link imports it from Eaon Desktop"}`);
          checks.push(`- BYOK providers: ${config.customProviders.length}`);
          checks.push(`- Config file: ${configFile()}${fs.existsSync(configFile()) ? " ✓" : " (not written yet — created on first change)"}`);
          checks.push(`- Project memory: ${readProjectNotes(projectRoot) ? `${PROJECT_NOTES_FILE} loaded ✓` : `no ${PROJECT_NOTES_FILE} — run /init to create one`}`);
          checks.push(`- Models in catalog: ${catalog.length}`);
          pushMarkdown(["## Doctor", "", ...checks].join("\n"));
          return;
        }
        case "show_config": {
          const redacted = {
            ...config,
            aquaApiKey: redactKey(resolveAquaApiKey(config)),
            customProviders: config.customProviders.map((p) => ({ ...p, apiKey: redactKey(p.apiKey) })),
          };
          pushMarkdown(["## Config", "", `**File:** ${configFile()}`, "", "```json", JSON.stringify(redacted, null, 2), "```"].join("\n"));
          return;
        }
        case "memory": {
          const notesPath = path.join(projectRoot, PROJECT_NOTES_FILE);
          try {
            if (!fs.existsSync(notesPath)) {
              fs.writeFileSync(notesPath, `# ${path.basename(projectRoot)}\n\nNotes for Eaon about this project — conventions, commands, gotchas. Loaded into every session here.\n`, "utf8");
              pushSystem(`Created ${PROJECT_NOTES_FILE}.`, "success");
            }
          } catch (e) {
            pushSystem(`Couldn't create ${PROJECT_NOTES_FILE}: ${e instanceof Error ? e.message : String(e)}`, "error");
            return;
          }
          try {
            await open(notesPath);
            pushSystem(`Opened ${notesPath} — it's loaded into every session in this project.`);
          } catch {
            pushSystem(`Couldn't open an editor — the file is at ${notesPath}.`, "error");
          }
          return;
        }
        case "export": {
          const target = outcome.path
            ? path.resolve(projectRoot, outcome.path)
            : path.join(projectRoot, `eaon-session-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.md`);
          try {
            fs.writeFileSync(target, transcriptMarkdown(turnsRef.current, model ? describeEntry(model) : "unknown"), "utf8");
            pushSystem(`Exported to ${target}`, "success");
          } catch (e) {
            pushSystem(`Export failed: ${e instanceof Error ? e.message : String(e)}`, "error");
          }
          return;
        }
        case "exit":
          persistCurrentSession();
          exit();
          return;
      }
    },
    [catalog, model, config, mode, permissionMode, projectRoot, handlePull, handleLink, handleCompact, pushSystem, pushMarkdown, persistCurrentSession, exit]
  );

  // `@`-mention autocomplete source — the project's file list, lazily built
  // and cached (see fileIndexRef).
  const queryFiles = useCallback(
    (q: string): string[] => {
      if (fileIndexRef.current === null) fileIndexRef.current = listProjectFiles(projectRoot);
      const idx = fileIndexRef.current;
      const query = q.toLowerCase();
      if (!query) return idx.slice(0, 6);
      return idx.filter((f) => f.toLowerCase().includes(query)).slice(0, 20);
    },
    [projectRoot]
  );

  // Expands `@path` references in a message into the actual file contents
  // the model sees — the user's on-screen message stays as they typed it,
  // but the turn sent to the model carries the referenced files inline, so
  // "explain @src/app.ts" just works without a separate read_file round-trip.
  const expandMentions = useCallback(
    (text: string): string => {
      const rels = [...text.matchAll(/(^|\s)@([^\s@]+)/g)].map((m) => m[2]);
      if (rels.length === 0) return text;
      const blocks: string[] = [];
      for (const rel of rels) {
        if (blocks.length >= 5) break;
        try {
          const full = path.resolve(projectRoot, rel);
          if (full !== projectRoot && !full.startsWith(projectRoot + path.sep)) continue; // stay inside the project
          const stat = fs.statSync(full);
          if (!stat.isFile() || stat.size > 200_000) continue;
          const content = fs.readFileSync(full, "utf8");
          const capped = content.length > 8000 ? content.slice(0, 8000) + "\n…(truncated)" : content;
          blocks.push(`@${rel}:\n\`\`\`\n${capped}\n\`\`\``);
        } catch {
          // unreadable / missing / binary — skip, the bare @path stays in the text
        }
      }
      return blocks.length === 0 ? text : `${text}\n\nReferenced files:\n${blocks.join("\n\n")}`;
    },
    [projectRoot]
  );

  // `!command` — run a shell command directly (Claude-Code's bash mode). The
  // output is shown as a tool row AND folded into the conversation as
  // context, so the model can reason about it on the next turn, but it does
  // NOT trigger a model reply on its own.
  const handleBash = useCallback(
    async (command: string) => {
      if (command.length === 0) {
        pushSystem("Nothing to run — type a command after !, e.g. !ls -la", "info");
        return;
      }
      const id = randomUUID();
      setMessages((prev) => [...prev, { id, role: "tool", name: "run_shell", summary: `Bash`, args: { command }, pending: true }]);
      let result;
      try {
        result = await runShell({ command }, { projectRoot } as PathGuardContext);
      } catch (e) {
        result = { isError: true, text: e instanceof Error ? e.message : String(e) };
      }
      const finished = result;
      setMessages((prev) =>
        prev.map((m) => (m.id === id && m.role === "tool" ? { ...m, pending: false, result: { isError: finished.isError, text: finished.text } } : m))
      );
      turnsRef.current.push({ role: "user", content: `I ran this shell command myself:\n$ ${command}\n\nOutput:\n${finished.text}` });
      setContextTokens(estimateTokens(turnsRef.current));
      persistCurrentSession();
    },
    [projectRoot, pushSystem, persistCurrentSession]
  );

  // `#note` — append a line to this project's EAON.md (Claude-Code's `#`
  // quick-memory). No model round-trip; it just persists the note.
  const handleMemoryNote = useCallback(
    (note: string) => {
      if (note.length === 0) {
        pushSystem("Nothing to save — write the note after #, e.g. # always run tests with pnpm test", "info");
        return;
      }
      const notesPath = path.join(projectRoot, PROJECT_NOTES_FILE);
      try {
        const existing = fs.existsSync(notesPath) ? fs.readFileSync(notesPath, "utf8") : `# ${path.basename(projectRoot)}\n\nNotes for Eaon about this project — loaded into every session here.\n`;
        const updated = existing.replace(/\s*$/, "") + `\n- ${note}\n`;
        fs.writeFileSync(notesPath, updated, "utf8");
        pushSystem(`Saved to ${PROJECT_NOTES_FILE}: “${note}”`, "success");
      } catch (e) {
        pushSystem(`Couldn't write ${PROJECT_NOTES_FILE}: ${e instanceof Error ? e.message : String(e)}`, "error");
      }
    },
    [projectRoot, pushSystem]
  );

  const handleSubmit = useCallback(
    (text: string) => {
      const slash = parseSlashCommand(text);
      if (slash) {
        // A slash command while a turn is generating (e.g. /clear, /model)
        // runs immediately rather than queuing — those aren't a new
        // message to the model, so there's nothing to redirect.
        setSubmitHistory((h) => [...h, text]);
        void handleCommand(slash.command.name, slash.args).catch((e) =>
          pushSystem(`Command failed: ${e instanceof Error ? e.message : String(e)}`, "error")
        );
        return;
      }
      // `!` bash and `#` memory are local side-actions — they don't go to
      // the model and don't interrupt an in-flight turn's text.
      if (text.startsWith("!")) {
        setSubmitHistory((h) => [...h, text]);
        void handleBash(text.slice(1).trim()).catch((e) => pushSystem(`Shell error: ${e instanceof Error ? e.message : String(e)}`, "error"));
        return;
      }
      if (text.startsWith("#")) {
        setSubmitHistory((h) => [...h, text]);
        handleMemoryNote(text.slice(1).trim());
        return;
      }
      setSubmitHistory((h) => [...h, text]);
      if (isGenerating) {
        // Interrupt: stop the in-flight turn now, and let it hand off to
        // this new message once it's actually finished unwinding (see
        // runLoop's finally) — exactly Claude Code's "just start typing
        // to redirect" behavior instead of forcing Esc-then-retype.
        // (Raw text, not mention-expanded: the resubmit string is shown
        // on screen verbatim in runLoop's finally, so expanding it would
        // dump file contents into the transcript.)
        interruptResubmitRef.current = text;
        abortRef.current?.abort();
        return;
      }
      setMessages((prev) => [...prev, { id: randomUUID(), role: "user", text }]);
      turnsRef.current.push({ role: "user", content: expandMentions(text) });
      void runLoop().catch((e) => pushSystem(`Unexpected error: ${e instanceof Error ? e.message : String(e)}`, "error"));
    },
    [handleCommand, runLoop, isGenerating, pushSystem, handleBash, handleMemoryNote, expandMentions]
  );

  const handleTogglePermission = useCallback(() => {
    if (isGenerating) return;
    if (permissionMode === "sandboxed") setConfirmingAuto(true);
    else {
      setPermissionMode("sandboxed");
      pushSystem("Switched to Sandboxed — every action will ask first.");
    }
  }, [permissionMode, isGenerating, pushSystem]);

  const handleAutoAnswer = useCallback(
    (yes: boolean) => {
      setConfirmingAuto(false);
      if (yes) {
        setPermissionMode("auto");
        pushSystem("Switched to Auto — actions run immediately.");
      }
    },
    [pushSystem]
  );

  const handleCancel = useCallback(() => {
    if (abortRef.current) {
      abortRef.current.abort();
      pushSystem("Cancelled.");
    }
  }, [pushSystem]);

  const handlePermissionAnswer = useCallback((answer: PermissionAnswer) => {
    permissionResolveRef.current?.(answer);
  }, []);

  const handleModelPickerSelect = useCallback(
    (chosen: ModelEntry) => {
      setModel(chosen);
      const nextConfig = { ...config, selectedModelKey: chosen.key };
      setConfig(nextConfig);
      saveConfig(nextConfig);
      setModelPickerOpen(false);
      pushSystem(`Switched to ${describeEntry(chosen)}.`, "success");
    },
    [config, pushSystem]
  );

  const handleModelPickerCancel = useCallback(() => {
    setModelPickerOpen(false);
  }, []);

  // Global Ctrl+C (press twice to exit) — always active, alongside whichever
  // other input hook (Composer/PermissionPrompt/AutoModeConfirm) is live.
  useInput((input, key) => {
    if (key.ctrl && input === "c") {
      const now = Date.now();
      if (now - lastCtrlCRef.current < 1500) {
        persistCurrentSession();
        exit();
      } else {
        lastCtrlCRef.current = now;
        pushSystem("Press Ctrl+C again to exit.");
      }
    }
  });

  // A tool row starts pending and gets mutated in place once its result
  // lands (see runLoop's "tool_result" handler) — it must stay out of
  // <Static> (which never re-renders an item it already committed) until
  // that mutation has happened, or its final ✓/✗ never appears on screen.
  const isLive = (m: DisplayMessage) => (m.role === "assistant" && m.streaming) || (m.role === "tool" && m.pending);
  const completed = messages.filter((m) => !isLive(m));
  const live = messages.filter(isLive);
  // Deliberately NOT gated on isGenerating: typing (and Esc) while the
  // model is mid-turn is how an interrupt happens (see handleSubmit /
  // handleCancel) — Claude Code's own "just start typing to redirect"
  // behavior, rather than forcing Esc-then-wait-then-retype.
  const composerActive = !pendingPermission && !confirmingAuto && !modelPickerOpen;

  return (
    <Box flexDirection="column">
      <Static key={historyEpoch} items={completed}>
        {(m) => (
          <ErrorBoundary key={m.id} label="A message couldn't be displayed">
            <MessageView message={m} />
          </ErrorBoundary>
        )}
      </Static>
      {live.map((m) => (
        <ErrorBoundary key={m.id} label="A message couldn't be displayed">
          <MessageView message={m} />
        </ErrorBoundary>
      ))}

      {statusText && (
        <Box marginTop={1}>
          <Text color={theme.muted}>{statusText}</Text>
        </Box>
      )}

      {/* Pinned checklist while the agent works through multi-step tasks —
          hidden once everything is completed. todoVersion re-reads it. */}
      {(() => {
        void todoVersion;
        const todos = currentTodos();
        if (todos.length === 0 || todos.every((t) => t.status === "completed")) return null;
        return (
          <Box flexDirection="column" borderStyle="round" borderColor={theme.muted} paddingX={1} marginTop={1}>
            {todos.map((t, i) => (
              <Text key={i} color={t.status === "completed" ? theme.muted : t.status === "in_progress" ? theme.accent : theme.assistant} strikethrough={t.status === "completed"}>
                {t.status === "completed" ? "☑" : t.status === "in_progress" ? "◐" : "☐"} {t.content}
              </Text>
            ))}
          </Box>
        );
      })()}

      {pendingPermission && (
        <PermissionPrompt name={pendingPermission.name} summary={pendingPermission.summary} detail={pendingPermission.detail} onAnswer={handlePermissionAnswer} />
      )}
      {confirmingAuto && <AutoModeConfirm onAnswer={handleAutoAnswer} />}
      {modelPickerOpen && (
        <ModelPicker models={catalog} currentKey={model?.key ?? null} onSelect={handleModelPickerSelect} onCancel={handleModelPickerCancel} />
      )}

      <Box marginTop={1}>
        <Composer
          isActive={composerActive}
          history={submitHistory}
          onSubmit={handleSubmit}
          onTogglePermission={handleTogglePermission}
          onCancel={handleCancel}
          queryFiles={queryFiles}
          mode={mode}
          permissionMode={permissionMode}
        />
      </Box>
      {isGenerating && <GenerationStatus />}
      <Box justifyContent="space-between">
        <Text color={theme.muted}>
          {MODE_LABEL[mode]} · {model ? describeEntry(model) : catalogLoading ? "Loading models…" : "no model — /model"}
          {contextTokens > 0 ? ` · ~${contextTokens >= 1000 ? `${(contextTokens / 1000).toFixed(1)}k` : contextTokens} tokens` : ""}
        </Text>
        <Text color={permissionMode === "auto" ? PERMISSION_COLORS.auto : PERMISSION_COLORS.sandboxed}>
          {permissionMode === "auto" ? "⏵⏵ auto-accept · shift+tab" : "○ sandboxed · shift+tab"}
        </Text>
      </Box>
    </Box>
  );
}
