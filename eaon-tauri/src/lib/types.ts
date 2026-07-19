// Core data shapes — mirrors the Mac app's ChatMessage/Conversation/Project
// structs (ChatViewModel.swift) so persisted state means the same things.

export type Role = "user" | "assistant";

export type AttachmentKind = "image" | "file";

/** A file/image attached to a message — mirrors the Mac MessageAttachment.
 *  The bytes live in the app data dir's attachments/ folder under
 *  `storedFileName`; the message only carries this reference. */
export interface MessageAttachment {
  id: string;
  fileName: string;
  kind: AttachmentKind;
  storedFileName: string;
  /** Mime of the stored bytes (images are normalized to PNG on import). */
  mimeType: string;
}

/** One element of an OpenAI content-parts array — the vision wire shape. */
export type ContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

export interface ChatMessage {
  id: string;
  role: Role;
  content: string;
  /** Reasoning-model chain-of-thought, streamed separately. */
  reasoning: string;
  isError?: boolean;
  modelId?: string;
  modelDisplay?: string;
  timestamp: number;
  generationStartTime?: number;
  generationEndTime?: number;
  generatedTokenCount?: number;
  /** Set when this user message was sent via a "/name" skill invocation. */
  invokedSkillName?: string;
  /** An automated Agent tool-results message (run output, edits) — rendered
   *  as a compact collapsed card, not as normal prose. Mirrors the Mac
   *  ChatMessage.isToolResult. */
  isToolResult?: boolean;
  /** Files/images attached to this (user) message. */
  attachments?: MessageAttachment[];
}

export interface Conversation {
  id: string;
  title: string;
  messages: ChatMessage[];
  createdAt: number;
  updatedAt: number;
  hasUnread?: boolean;
  projectId?: string | null;
  isPinned?: boolean;
}

export interface Project {
  id: string;
  name: string;
  createdAt: number;
}

/** A durable fact/event Eaon remembers about the user and brings into future
 *  chats — mirrors the Mac app's Memory. */
export interface Memory {
  id: string;
  text: string;
  kind: "fact" | "event";
  createdAt: number;
}

/** A BYOK connection — mirrors CustomProviderConfig. */
export interface CustomProvider {
  id: string;
  displayName: string;
  baseURL: string;
  apiKey: string;
  /** User-entered model ids this connection serves. */
  modelIDs: string[];
}

/** One configured MCP server — a remote Streamable-HTTP service (URL +
 *  pasted token) or a local stdio process (command + args). */
export interface McpServer {
  id: string;
  name: string;
  transport: "http" | "stdio";
  url: string;
  /** Authorization scheme word — "Bearer" for nearly everyone; Sentry and
   *  Semrush genuinely differ. */
  authScheme: string;
  token: string;
  command: string;
  /** Space-separated in the UI, split for spawn. */
  args: string;
  /** Disabled servers stay configured but are never connected. */
  enabled: boolean;
}

/** One tool a connected MCP server offers (name + JSON Schema). */
export interface McpToolInfo {
  name: string;
  description: string | null;
  inputSchema: Record<string, unknown>;
}

/** Which wire shape an image connection speaks — mirrors ImageWireFormat.
 *  "openai": a cloud /images/generations API (DALL-E, gpt-image, or any
 *  compatible provider). "automatic1111": a local Stable Diffusion server
 *  (A1111 WebUI, DrawThings, ComfyUI in compatibility mode). */
export type ImageWireFormat = "openai" | "automatic1111";

/** One image-generation connection — mirrors ImageProviderConfig. */
export interface ImageProvider {
  id: string;
  displayName: string;
  baseURL: string;
  format: ImageWireFormat;
  apiKey: string;
  /** Model ids for "openai"; for "automatic1111" whatever's loaded in the
   *  local tool runs, so this is just a display label. */
  modelIDs: string[];
}

export type ThemeChoice = "Light" | "Dark" | "System";
export type FontSizeChoice = "Small" | "Medium" | "Large";
export type EaonMode = "chat" | "agent" | "claw";

export interface Settings {
  theme: ThemeChoice;
  fontSize: FontSizeChoice;
  accentColorId: string;
  coloredUserBubble: boolean;
  showTokenSpeed: boolean;
  customInstructions: string;
  aquaApiKey: string;
  customProviders: CustomProvider[];
  ollamaBaseUrl: string;
  webSearchEnabled: boolean;
  alwaysAllowTools: boolean;
  /** Folds the wider device tools (trash/open app/URL — formerly Eaon Claw)
   *  into Agent mode. Off by default. */
  deviceControlEnabled: boolean;
  /** Optional outbound HTTP(S) proxy, e.g. "http://127.0.0.1:8080". */
  proxyEnabled: boolean;
  proxyUrl: string;
  hasSeenOnboarding: boolean;
  favorites: string[];
  nicknames: Record<string, string>;
  skills: Skill[];
  /** Facts Eaon has learned about the user, injected into future chats. */
  memories: Memory[];
  /** Whether Eaon auto-learns durable facts from conversations. */
  memoryEnabled: boolean;
  /** Configured image-generation connections (cloud or local SD server). */
  imageProviders: ImageProvider[];
  /** Whether chat models may generate images via the eaon:image tool. */
  imageToolEnabled: boolean;
  /** Global sampling parameters — each independently opt-in; an off toggle
   *  means the field is NOT sent at all (mirrors ModelParametersStore). */
  modelParams: ModelParams;
  /** Configured MCP plugin servers. */
  mcpServers: McpServer[];
  /** Off by default — turning this on opens a real listening network port. */
  localServerEnabled: boolean;
  /** 1234 by default — matches LM Studio's own local-server port. */
  localServerPort: number;
  localServerRequireApiKey: boolean;
  localServerApiKey: string;
}

/** Mirrors ModelParametersStore — one global set, every field opt-in. */
export interface ModelParams {
  temperatureEnabled: boolean;
  temperature: number;
  topPEnabled: boolean;
  topP: number;
  maxTokensEnabled: boolean;
  maxTokens: number;
  frequencyPenaltyEnabled: boolean;
  frequencyPenalty: number;
  presencePenaltyEnabled: boolean;
  presencePenalty: number;
}

export interface Statistics {
  promptsSent: number;
  charsGenerated: number;
  perModel: Record<string, { prompts: number; chars: number }>;
}

/** Where an installed skill came from — display-only, never affects behavior. */
export type SkillSource =
  | { kind: "starter" }
  | { kind: "localImport"; path: string }
  | { kind: "github"; url: string }
  | { kind: "manual" };

/**
 * One installed skill — mirrors Claude Code's own SKILL.md shape (a name, a
 * one-line description, and an instruction body), invoked with `/name` in
 * the composer.
 */
export interface Skill {
  id: string;
  /** Lowercase, hyphenated — what the user types after `/`. */
  name: string;
  summary: string;
  instructions: string;
  source: SkillSource;
  /** Disabled skills stay installed but are invisible to `/` autocomplete. */
  isEnabled: boolean;
  installedAt: number;
}

export interface OllamaModel {
  name: string;
  sizeBytes: number;
  paramSize?: string | null;
  quantization?: string | null;
  family?: string | null;
  /** Ollama's real capability tags ("completion", "vision", "image", …). */
  capabilities?: string[] | null;
}

export interface ProviderModel {
  id: string;
  name?: string | null;
  modelType?: string | null;
  tier?: string | null;
}

/** A selectable chat model with its serving connection resolved. */
export interface ModelEntry {
  /** Unique picker key, e.g. "aqua:gpt-5.5", "ollama:gemma4:e2b", "custom:<cfg>:<id>". */
  key: string;
  /** The id sent in the request "model" field. */
  requestId: string;
  display: string;
  provider:
    | { kind: "aqua" }
    | { kind: "ollama" }
    | { kind: "custom"; configId: string; configName: string };
  tier?: string | null;
}

export type SidebarSelection =
  | { kind: "chat" }
  | { kind: "projects" }
  | { kind: "models" }
  | { kind: "project"; id: string };

export interface PullState {
  status: string;
  completed: number;
  total: number;
  error?: string;
}
