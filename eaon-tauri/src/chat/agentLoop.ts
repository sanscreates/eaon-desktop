// The multi-turn loop — stream a reply, execute the tool fences it emitted,
// feed the results back, repeat. The port of REF state.svelte.ts's
// runAgentLoop + the chat-mode fence round-trip, unified: chat mode loops on
// eaon:search / eaon:mcp (and resolves eaon:image), agent mode on
// eaon:computer tool calls plus search/image.

import { chatStream, mcpCall, webSearch } from "../core/ipc";
import { uid } from "../core/utils";
import {
  formatSearchResults,
  parseSearchQueries,
  stripSearchFences,
} from "../core/protocol/search";
import { parseImagePrompts, stripImageFences } from "../core/protocol/images";
import { detailedSpec, parseMcpCalls, stripMcpFences, type McpCall } from "../core/protocol/mcp";
import {
  DEVICE_TOOLS,
  isReadOnlyTool,
  parseToolCalls,
  resolveWorkspacePaths,
  runTool,
  toolDetail,
  toolSummary,
  type ToolCall,
} from "../core/protocol/agent";
import { useConversations } from "../state/conversations";
import { useGeneration, nextRequestId } from "../state/generation";
import { useSettings } from "../state/settings";
import {
  allowAllForConversation,
  connectedMcpTools,
  conversationAllowsAll,
  friendlyStreamError,
  requestAgentAnswer,
  requestToolConfirm,
  type TurnContext,
} from "./internal";
import { executeImagePrompts, extractMemories, finalizeTurn } from "./postTurn";

/** Caps: an agent run may legitimately take many build/run/fix rounds; a
 *  chat that keeps searching past this is confused, not thorough. */
const MAX_AGENT_TURNS = 40;
const MAX_CHAT_TURNS = 16;
/** The same action failing identically this many times in a row means the
 *  model is stuck in a loop — stop burning requests. */
const MAX_IDENTICAL_FAILURES = 3;

/** protocol/agent.ts exports no stripper (REF left computer fences visible);
 *  same fence grammar as its parseToolCalls, removed once executed so the
 *  bubble keeps prose, not plumbing. */
function stripComputerFences(text: string): string {
  return text
    .replace(/```[^\S\n]*eaon:computer[^\n]*\n[\s\S]*?```/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function isStopped(conversationId: string): boolean {
  return useGeneration.getState().sessions[conversationId]?.stopped === true;
}

interface TurnResult {
  content: string;
  reasoning: string;
  errored: boolean;
}

/** One streamed reply into `messageId`. Store writes are coalesced to
 *  ~40ms — token events arrive far faster than React should re-render, and
 *  every updateMessage rebuilds the conversation array. */
async function streamTurn(ctx: TurnContext, messageId: string, requestId: number): Promise<TurnResult> {
  const { conversationId, route } = ctx;
  let content = "";
  let reasoning = "";
  let errored = false;

  let flushTimer: number | null = null;
  const flush = () => {
    flushTimer = null;
    useConversations.getState().updateMessage(conversationId, messageId, (m) => ({
      ...m,
      content,
      reasoning,
    }));
  };
  const scheduleFlush = () => {
    if (flushTimer === null) flushTimer = window.setTimeout(flush, 40);
  };

  try {
    await chatStream(
      {
        baseUrl: route.baseUrl,
        apiKey: route.apiKey,
        trialDevice: route.trialDevice,
        trialSecret: route.trialSecret,
        model: route.requestModel,
        messages: ctx.history,
        requestId,
        sampling: ctx.sampling,
        format: route.format,
      },
      (event) => {
        if (event.type === "token") {
          content += event.text;
          scheduleFlush();
        } else if (event.type === "reasoning") {
          reasoning += event.text;
          scheduleFlush();
        } else if (event.type === "error") {
          errored = true;
          content = content || friendlyStreamError(event.message);
        }
      },
    );
  } catch (e) {
    errored = true;
    content = content || friendlyStreamError(e instanceof Error ? e.message : String(e));
  }

  if (flushTimer !== null) clearTimeout(flushTimer);
  useConversations.getState().updateMessage(conversationId, messageId, (m) => ({
    ...m,
    content,
    reasoning,
    isError: errored ? true : m.isError,
  }));
  return { content, reasoning, errored };
}

/** Chat-mode eaon:mcp execution with the Sandboxed confirmation — REF
 *  executeMcpCalls, against the live registry. The dialog shows the real
 *  service+tool and the FULL argument JSON: a live account action never
 *  hides behind a tidy one-liner. */
async function executeMcpCalls(ctx: TurnContext, calls: McpCall[], failures: string[]): Promise<string[]> {
  const sections: string[] = [];
  const { settings } = useSettings.getState();
  for (const call of calls) {
    if (isStopped(ctx.conversationId)) break;
    const label = `${call.serverId} › ${call.tool}`;
    const connected = connectedMcpTools().find((s) => s.serverId === call.serverId);
    if (!connected) {
      const ids = connectedMcpTools().map((s) => s.serverId).join(", ") || "(none)";
      sections.push(`### ${label}\nERROR: "${call.serverId}" is not a connected service — the connected server ids are exactly: ${ids}.`);
      failures.push(`mcp:${call.serverId}.${call.tool}|unconnected`);
      continue;
    }
    const tool = connected.tools.find((t) => t.name === call.tool);
    if (call.parseError) {
      sections.push(`### ${label}\nERROR: the block body wasn't valid JSON. ${tool ? detailedSpec(tool) : ""}`);
      failures.push(`mcp:${call.serverId}.${call.tool}|badjson`);
      continue;
    }
    if (!settings.alwaysAllowTools && !conversationAllowsAll(ctx.conversationId)) {
      const decision = await requestToolConfirm(
        ctx.conversationId,
        `Call ${call.tool} on ${connected.name}`,
        JSON.stringify(call.args, null, 2),
      );
      if (decision === "deny") {
        sections.push(`### ${label}\n[User denied this action]`);
        continue;
      }
      if (decision === "always") allowAllForConversation(ctx.conversationId);
    }
    try {
      const result = await mcpCall(call.serverId, call.tool, call.args);
      sections.push(`### ${label}\n${result}`);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      sections.push(`### ${label}\nERROR: ${message}${tool ? `\n${detailedSpec(tool)}` : ""}`);
      failures.push(`mcp:${call.serverId}.${call.tool}|${message.slice(0, 120)}`);
    }
  }
  return sections;
}

/** Agent-mode tool execution with the full confirmation model: read-only
 *  runs free; Auto mode (agentAutoRun) and the alwaysAllowTools setting
 *  bypass; otherwise the dialog decides once/always/deny; ask_user pauses
 *  on its own dialog and the answer IS the tool result (REF runAgentLoop). */
async function executeAgentTools(ctx: TurnContext, calls: ToolCall[], failures: string[]): Promise<string[]> {
  const sections: string[] = [];
  const { settings } = useSettings.getState();
  for (const rawCall of calls) {
    if (isStopped(ctx.conversationId)) break;
    // Workspace resolution first, so the confirmation dialog (and the tool
    // itself) sees the real absolute path, never an ambiguous relative one.
    const call = resolveWorkspacePaths(rawCall, settings.agentWorkspace);
    if (call.name === "ask_user") {
      const question = String(call.args.question ?? "").trim();
      const options = Array.isArray(call.args.options)
        ? call.args.options.map(String).filter(Boolean).slice(0, 4)
        : [];
      if (!question) {
        sections.push(`### ask_user\nERROR: ask_user needs a "question".`);
        failures.push(`tool:ask_user|missing-question`);
        continue;
      }
      const answer = await requestAgentAnswer(ctx.conversationId, question, options);
      sections.push(`### ask_user\nThe user answered: ${answer}`);
      continue;
    }
    // Device tools only exist while device control is on — refused at
    // execution time too, in case a model emits one unprompted.
    if (DEVICE_TOOLS.has(call.name) && !settings.deviceControlEnabled) {
      sections.push(`### ${call.name}\nERROR: device control is turned off in Settings.`);
      failures.push(`tool:${call.name}|device-off`);
      continue;
    }
    const autoAllowed =
      settings.alwaysAllowTools ||
      useGeneration.getState().agentAutoRun ||
      conversationAllowsAll(ctx.conversationId);
    if (!isReadOnlyTool(call.name) && !autoAllowed) {
      const decision = await requestToolConfirm(ctx.conversationId, toolSummary(call), toolDetail(call));
      if (decision === "deny") {
        sections.push(`### ${call.name}\n[User denied this action]`);
        continue;
      }
      if (decision === "always") allowAllForConversation(ctx.conversationId);
    }
    const outcome = await runTool(call);
    sections.push(`### ${call.name}\n${outcome.ok ? "OK" : "ERROR"}:\n${outcome.text}`);
    if (!outcome.ok) failures.push(`tool:${call.name}|${call.rawBody}`);
  }
  return sections;
}

/** The streamed turn loop for one send. Assumes send.ts already appended
 *  the first assistant placeholder and began the session. */
export async function runTurns(ctx: TurnContext): Promise<void> {
  const maxTurns = ctx.mode === "agent" ? MAX_AGENT_TURNS : MAX_CHAT_TURNS;
  let messageId = ctx.firstAssistantId;
  let requestId = ctx.firstRequestId;
  let lastGoodContent = "";
  let lastFailureSig = "";
  let identicalFailures = 0;

  for (let turn = 0; turn < maxTurns; turn++) {
    if (turn > 0) {
      if (isStopped(ctx.conversationId)) break;
      messageId = uid();
      requestId = nextRequestId();
      useConversations.getState().appendMessage(ctx.conversationId, {
        id: messageId,
        role: "assistant",
        content: "",
        reasoning: "",
        modelId: ctx.entry.key,
        modelDisplay: ctx.entry.display,
        timestamp: Date.now(),
        generationStartTime: Date.now(),
      });
      // Re-point the session at this turn's stream so the stop button
      // cancels the live request (REF: session.requestId = requestId). No
      // await between the stopped check above and this, so a stop can't be
      // silently un-flagged.
      useGeneration.getState().begin(ctx.conversationId, requestId);
    }

    const result = await streamTurn(ctx, messageId, requestId);
    finalizeTurn(ctx.conversationId, messageId, ctx.entry.key, result.content);
    if (result.errored || isStopped(ctx.conversationId)) break;
    lastGoodContent = result.content;
    ctx.history.push({ role: "assistant", content: result.content });

    // Parse this reply's fences — chat mode: search/image/mcp; agent mode:
    // computer tools plus search/image.
    const { settings } = useSettings.getState();
    const searchQueries = settings.webSearchEnabled ? parseSearchQueries(result.content).slice(0, 3) : [];
    const imagePrompts = settings.imageToolEnabled ? parseImagePrompts(result.content).slice(0, 3) : [];
    // Plugins work in both modes — the Agent pairs its computer tools with
    // the user's connected MCP services, mirroring send.ts's prompt gating.
    const mcpCalls = parseMcpCalls(result.content).slice(0, 5);
    const toolCalls = ctx.mode === "agent" ? parseToolCalls(result.content) : [];
    if (!searchQueries.length && !imagePrompts.length && !mcpCalls.length && !toolCalls.length) break;

    // Strip only the fence kinds that will actually execute; keep the prose.
    let visible = result.content;
    if (searchQueries.length) visible = stripSearchFences(visible);
    if (imagePrompts.length) visible = stripImageFences(visible);
    if (mcpCalls.length) visible = stripMcpFences(visible);
    if (toolCalls.length) visible = stripComputerFences(visible);
    useConversations.getState().updateMessage(ctx.conversationId, messageId, (m) => ({ ...m, content: visible }));
    lastGoodContent = visible;

    if (imagePrompts.length) {
      // Generates and attaches onto this same reply (REF resolveImageFences).
      await executeImagePrompts(imagePrompts, ctx.conversationId, messageId);
    } else if (!visible && !result.reasoning) {
      // The reply was nothing but tool calls — drop the empty bubble; the
      // results card and the follow-up reply tell the story (REF drops it
      // the same way). It's the newest message, so truncateFrom removes
      // exactly it.
      useConversations.getState().truncateFrom(ctx.conversationId, messageId);
    }

    // Image fences are terminal side effects — nothing to feed back.
    if (!searchQueries.length && !mcpCalls.length && !toolCalls.length) break;

    const failures: string[] = [];
    const sections: string[] = [];
    for (const query of searchQueries) {
      if (isStopped(ctx.conversationId)) break;
      try {
        const hits = await webSearch(query);
        sections.push(`### web_search: ${query}\n${formatSearchResults(hits)}`);
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        sections.push(`### web_search: ${query}\nERROR: ${message}`);
        failures.push(`search:${query}|${message.slice(0, 120)}`);
      }
    }
    sections.push(...(await executeMcpCalls(ctx, mcpCalls, failures)));
    sections.push(...(await executeAgentTools(ctx, toolCalls, failures)));
    if (isStopped(ctx.conversationId)) break;

    // Persisted as an isToolResult card with user role — REF's exact
    // convention: user-role on the wire (so the model reads it as input),
    // rendered as a collapsed card, never as a user bubble.
    const resultsText = `[Tool results — automated, not written by the user]\n\n${sections.join("\n\n")}`;
    useConversations.getState().appendMessage(ctx.conversationId, {
      id: uid(),
      role: "user",
      content: resultsText,
      reasoning: "",
      timestamp: Date.now(),
      isToolResult: true,
    });
    ctx.history.push({ role: "user", content: resultsText });

    // Identical-failure breaker: the same calls failing the same way three
    // turns running is a stuck model, not progress.
    const failureSig = failures.join("\n");
    if (failureSig && failureSig === lastFailureSig) {
      identicalFailures += 1;
    } else {
      identicalFailures = failureSig ? 1 : 0;
      lastFailureSig = failureSig;
    }
    if (identicalFailures >= MAX_IDENTICAL_FAILURES) {
      useConversations.getState().appendMessage(ctx.conversationId, {
        id: uid(),
        role: "assistant",
        content: "Stopped — the same action kept failing the same way. Try rephrasing the request, or switch to a different model.",
        reasoning: "",
        isError: true,
        modelId: ctx.entry.key,
        modelDisplay: ctx.entry.display,
        timestamp: Date.now(),
      });
      break;
    }
  }

  // Background personalization off the finished exchange — fire-and-forget,
  // never blocks or surfaces (REF extractMemories call site).
  if (lastGoodContent.trim() && !isStopped(ctx.conversationId)) {
    void extractMemories(ctx.route, ctx.userText, lastGoodContent);
  }
}
