// Typed wrappers over the Rust commands (src-tauri/src/lib.rs). All network
// I/O happens in Rust; these are the only invoke() call sites.

import { invoke, Channel } from "@tauri-apps/api/core";
import type { ContentPart, McpToolInfo, OllamaModel, ProviderModel } from "./types";

export type StreamEvent =
  | { type: "token"; text: string }
  | { type: "reasoning"; text: string }
  | { type: "done"; cancelled: boolean }
  | { type: "error"; message: string };

/** One request turn — content is a plain string, or content-parts when the
 *  turn carries images for a vision model. Passed to the wire verbatim. */
export interface WireMessage {
  role: string;
  content: string | ContentPart[];
}

export interface ChatStreamArgs {
  baseUrl: string;
  apiKey: string | null;
  model: string;
  messages: WireMessage[];
  requestId: number;
  /** OpenAI sampling fields the user explicitly enabled (temperature,
   *  top_p, …) — omitted entirely otherwise. */
  sampling?: Record<string, number> | null;
  onEvent: (event: StreamEvent) => void;
}

export async function chatStream(args: ChatStreamArgs): Promise<void> {
  const channel = new Channel<StreamEvent>();
  channel.onmessage = args.onEvent;
  await invoke("chat_stream", {
    request: {
      baseUrl: args.baseUrl,
      apiKey: args.apiKey,
      model: args.model,
      messages: args.messages,
      requestId: args.requestId,
      sampling: args.sampling ?? null,
    },
    onEvent: channel,
  });
}

export function cancelStream(requestId: number): Promise<void> {
  return invoke("cancel_stream", { requestId });
}

/** A non-streaming completion — the whole answer as one string. Background
 *  work (memory extraction), not live chat. */
export function chatComplete(args: {
  baseUrl: string;
  apiKey: string | null;
  model: string;
  messages: Array<{ role: string; content: string }>;
}): Promise<string> {
  return invoke("chat_complete", {
    request: {
      baseUrl: args.baseUrl,
      apiKey: args.apiKey,
      model: args.model,
      messages: args.messages,
      requestId: 0,
    },
  });
}

export function ollamaTags(baseUrl: string): Promise<OllamaModel[]> {
  return invoke("ollama_tags", { baseUrl });
}

export type PullEvent =
  | { type: "progress"; status: string; completed: number; total: number }
  | { type: "done" }
  | { type: "error"; message: string };

export async function ollamaPull(
  baseUrl: string,
  model: string,
  onEvent: (event: PullEvent) => void
): Promise<void> {
  const channel = new Channel<PullEvent>();
  channel.onmessage = onEvent;
  await invoke("ollama_pull", { baseUrl, model, onEvent: channel });
}

export function ollamaDelete(baseUrl: string, model: string): Promise<void> {
  return invoke("ollama_delete", { baseUrl, model });
}

export function fetchProviderModels(baseUrl: string, apiKey: string | null): Promise<ProviderModel[]> {
  return invoke("fetch_provider_models", { baseUrl, apiKey });
}

export function loadAppState(): Promise<string> {
  return invoke("load_app_state");
}

export function saveAppState(json: string): Promise<void> {
  return invoke("save_app_state", { json });
}

export function fetchTextUrl(url: string): Promise<string> {
  return invoke("fetch_text_url", { url });
}

export interface ClaudeSkillCandidate {
  path: string;
  text: string;
}

export function scanClaudeSkills(): Promise<ClaudeSkillCandidate[]> {
  return invoke("scan_claude_skills");
}

// --- Network ---

/** Sets (or clears, with null) the proxy all outbound Rust HTTP uses.
 *  Rejects an unparseable proxy URL. */
export function setProxy(url: string | null): Promise<void> {
  return invoke("set_proxy", { url });
}

// --- Web search ---

export function webSearch(query: string): Promise<Array<{ url: string; snippet: string }>> {
  return invoke("web_search", { query });
}

// --- Image generation ---

export interface ImageGenResult {
  dataBase64: string;
  suggestedFileName: string;
}

/** One call, four wire shapes (openai / automatic1111 / ollama / aqua) —
 *  see generate_image in lib.rs. */
export function generateImage(args: {
  format: "openai" | "automatic1111" | "ollama" | "aqua";
  baseUrl: string;
  model: string;
  prompt: string;
  apiKey: string | null;
}): Promise<ImageGenResult> {
  return invoke("generate_image", { request: args });
}

// --- Attachments ---

/** Saves attachment bytes (base64, no data: prefix) and returns the stored
 *  file name the message should reference. */
export function saveAttachment(dataBase64: string, fileName: string): Promise<string> {
  return invoke("save_attachment", { dataBase64, fileName });
}

/** Reads a stored attachment back as base64 (no data: prefix). */
export function readAttachment(storedFileName: string): Promise<string> {
  return invoke("read_attachment", { storedFileName });
}

// --- Agent tools (Agent mode) ---

export interface ToolOutcome {
  ok: boolean;
  text: string;
}

export function runAgentTool(name: string, args: Record<string, unknown>): Promise<ToolOutcome> {
  return invoke("run_agent_tool", { name, args });
}

// --- MCP plugins ---

export interface McpConnectArgs {
  id: string;
  transport: "http" | "stdio";
  url?: string;
  authScheme?: string;
  token?: string;
  command?: string;
  args?: string[];
}

/** Connect (initialize + tools/list) — returns the server's tool catalog. */
export function mcpConnect(request: McpConnectArgs): Promise<McpToolInfo[]> {
  return invoke("mcp_connect", { request });
}

export function mcpCall(id: string, tool: string, args: Record<string, unknown>): Promise<{ isError: boolean; text: string }> {
  return invoke("mcp_call", { id, tool, args });
}

export function mcpDisconnect(id: string): Promise<void> {
  return invoke("mcp_disconnect", { id });
}

// --- Local API Server ---

export interface LocalServerUpstream {
  modelIds: string[];
  baseUrl: string;
  apiKey: string | null;
}

export interface LocalServerConfig {
  port: number;
  requireKey: boolean;
  apiKey: string;
  upstreams: LocalServerUpstream[];
}

export function startLocalServer(config: LocalServerConfig): Promise<void> {
  return invoke("start_local_server", { config });
}

export function stopLocalServer(): Promise<void> {
  return invoke("stop_local_server");
}

export function localServerRunning(): Promise<boolean> {
  return invoke("local_server_running");
}
