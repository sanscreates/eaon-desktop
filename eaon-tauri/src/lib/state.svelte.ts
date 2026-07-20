// The application state — the Svelte equivalent of the Mac app's
// ChatViewModel (@Observable). Same architecture decisions carried over:
// conversations persisted as one JSON blob, per-conversation generation
// sessions (a background chat keeps streaming when you switch away — the
// concurrency model the Mac app just adopted), verified-outcome flows, and
// a provider-merged model catalog (Aqua + BYOK + local Ollama).

import * as api from "./api";
import type {
  ChatMessage,
  Conversation,
  CustomProvider,
  McpServer,
  McpToolInfo,
  Memory,
  MessageAttachment,
  ModelEntry,
  OllamaModel,
  Project,
  PullState,
  Settings,
  Skill,
  SidebarSelection,
  Statistics,
} from "./types";
import { deriveTitle, uid } from "./utils";
import { buildContent, importFile } from "./attachments";
import { IMAGE_INSTRUCTION, parseImagePrompts, stripImageFences } from "./images";
import { formatSearchResults, parseSearchQueries, searchInstruction, stripSearchFences } from "./search";
import { speak, speakableText, stopSpeaking } from "./tts";
import { detailedSpec, mcpInstructionBlock, parseMcpCalls, stripMcpFences, type McpCall } from "./mcp";
import { candidateRawURLs, normalizeSkillName, parseSkill, STARTER_SKILLS } from "./skills";
import {
  agentInstruction,
  DEVICE_TOOLS,
  isReadOnlyTool,
  parseToolCalls,
  runTool,
  toolDetail,
  toolSummary,
  type ToolCall,
} from "./agent";
import {
  buildExtractionPrompt,
  memoryBlock,
  memoryKey,
  MEMORY_SYSTEM_PROMPT,
  parseExtraction,
} from "./memory";

export const EAON_HOSTED_BASE_URL = "https://api.aquadevs.com/v1";
export const DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434";

/** Aqua's hand-maintained chat allowlist — port of AquaSupportedModels. */
export const EAON_HOSTED_CATALOG: Record<string, string> = {
  "agnes": "Agnes 2.0 Flash", "deepseek-v3": "DeepSeek V3", "deepseek-v3.1": "DeepSeek V3.1 Terminus",
  "deepseek-v3.2": "DeepSeek V3.2", "deepseek-v4": "DeepSeek V4 Flash", "deepseek-v4-pro": "DeepSeek V4 Pro",
  "diffusion-gemma": "Diffusion Gemma 26B", "fable-5": "Claude Fable 5", "gemini-3": "Gemini 3.0 Flash",
  "gemini-3.1-lite": "Gemini 3.1 Flash Lite", "gemini-3.1-pro": "Gemini 3.1 Pro", "gemini-3.5": "Gemini 3.5 Flash",
  "gemma-4": "Gemma 4 31B", "glm-5.1": "GLM 5.1", "glm-5.2": "GLM 5.2", "gpt-5-nano": "GPT 5 Nano",
  "gpt-5.3-codex": "GPT 5.3 Codex", "gpt-5.4": "GPT 5.4", "gpt-5.4-mini": "GPT 5.4 Mini", "gpt-5.5": "GPT 5.5",
  "gpt-oss": "GPT-OSS 120B", "grok": "Grok 4.2 Fast", "grok-4.2-thinking": "Grok 4.2 Reasoning",
  "grok-4.3": "Grok 4.3", "haiku-4.5": "Claude Haiku 4.5", "hermes": "Hermes 4 70B", "kimi-k2.5": "Kimi K2.5",
  "kimi-k2.6": "Kimi K2.6", "kimi-k2.7": "Kimi K2.7 Code", "llama-3.1": "Llama 3.1 8B", "llama-4": "Llama 4 Maverick",
  "mercury": "Mercury 2", "mimo-v2.5": "Mimo V2.5", "mimo-v2.5-pro": "Mimo V2.5 Pro", "minimax-m2.7": "MiniMax M2.7",
  "minimax-m3": "MiniMax M3", "mistral": "Mistral", "mistral-3.5": "Mistral 3.5 128B", "nemotron": "Nemotron 3 Ultra",
  "nova": "Amazon Nova Fast", "opus-4.7": "Claude Opus 4.7", "opus-4.8": "Claude Opus 4.8", "qwen": "Qwen Coder",
  "qwen-3.6": "Qwen 3.6 27B", "qwen-3.7": "Qwen 3.7 Plus", "sonar": "Perplexity Sonar",
  "sonnet-4.6": "Claude Sonnet 4.6", "sonnet-5": "Claude Sonnet 5", "step-3.7": "Step 3.7 Flash",
};

const DEFAULT_SETTINGS: Settings = {
  theme: "Dark",
  fontSize: "Medium",
  accentColorId: "default",
  coloredUserBubble: false,
  showTokenSpeed: true,
  customInstructions: "",
  aquaApiKey: "",
  customProviders: [],
  ollamaBaseUrl: DEFAULT_OLLAMA_URL,
  webSearchEnabled: true,
  alwaysAllowTools: true,
  deviceControlEnabled: false,
  proxyEnabled: false,
  proxyUrl: "",
  hasSeenOnboarding: false,
  favorites: [],
  nicknames: {},
  skills: [],
  memories: [],
  memoryEnabled: true,
  imageProviders: [],
  imageToolEnabled: true,
  modelParams: {
    temperatureEnabled: false, temperature: 0.7,
    topPEnabled: false, topP: 1.0,
    maxTokensEnabled: false, maxTokens: 2048,
    frequencyPenaltyEnabled: false, frequencyPenalty: 0,
    presencePenaltyEnabled: false, presencePenalty: 0,
  },
  mcpServers: [],
  localServerEnabled: false,
  localServerPort: 1234,
  localServerRequireApiKey: true,
  localServerApiKey: "",
};

/** `eaon-local-` + 24 random alphanumeric chars — mirrors LocalAPIServerStore.generateKey. */
function generateLocalServerKey(): string {
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let key = "eaon-local-";
  for (let i = 0; i < 24; i++) key += chars[Math.floor(Math.random() * chars.length)];
  return key;
}

/** Accent options — port of AccentColorOption.all. */
export const ACCENT_OPTIONS: Array<{ id: string; color: string }> = [
  { id: "default", color: "#8E8E9C" }, { id: "aqua", color: "#F17455" }, { id: "white", color: "#FFFFFF" },
  { id: "red", color: "#e03e3e" }, { id: "orange", color: "#e8a838" }, { id: "yellow", color: "#c4b500" },
  { id: "lime", color: "#55a630" }, { id: "green", color: "#2d9f4f" }, { id: "mint", color: "#30b08c" },
  { id: "teal", color: "#2ec4b6" }, { id: "blue", color: "#3b82f6" }, { id: "indigo", color: "#5c6bc0" },
  { id: "purple", color: "#9b59b6" }, { id: "pink", color: "#e91e90" },
];

interface GenerationSession {
  requestId: number;
  streaming: boolean;
  /** Set by stopGeneration so a multi-step Agent turn breaks its loop
   *  instead of only cancelling the current stream. */
  stopped?: boolean;
}

/** A tool call paused for the user's go-ahead (Sandboxed mode) — the promise
 *  resolver is called by the confirmation dialog. Mirrors the Mac
 *  DesktopCallConfirmation continuation. */
export interface PendingToolConfirm {
  summary: string;
  detail: string | null;
  resolve: (decision: "once" | "always" | "deny") => void;
}

/** An ask_user question the Agent paused on — mirrors the Mac
 *  PendingAgentQuestion + its continuation. */
export interface PendingAgentQuestion {
  question: string;
  options: string[];
  resolve: (answer: string) => void;
}

let requestCounter = 1;

class AppState {
  conversations = $state<Conversation[]>([]);
  projects = $state<Project[]>([]);
  currentId = $state<string | null>(null);
  settings = $state<Settings>({ ...DEFAULT_SETTINGS });
  statistics = $state<Statistics>({ promptsSent: 0, charsGenerated: 0, perModel: {} });

  // Models
  ollamaModels = $state<OllamaModel[]>([]);
  ollamaReachable = $state(false);
  aquaModels = $state<Array<{ id: string; name: string | null; tier: string | null }>>([]);
  /** Aqua's hosted image-generation models (type == "image" from /models) —
   *  the tool channel's fallback backend when nothing else is configured. */
  aquaImageModels = $state<string[]>([]);
  isLoadingModels = $state(false);
  selectedModelKey = $state("");

  // Generation — per conversation, so a background chat keeps streaming.
  sessions = $state<Record<string, GenerationSession>>({});

  // Model downloads (Ollama pulls) in flight, keyed by model name.
  pulls = $state<Record<string, PullState>>({});

  // Local API Server — runtime status only; the settings themselves
  // (enabled/port/requireApiKey/apiKey) live in `settings`, persisted.
  localServerRunning = $state(false);
  localServerError = $state<string | null>(null);
  localServerRecentRequests = $state<string[]>([]);

  // UI
  selection = $state<SidebarSelection>({ kind: "chat" });
  sidebarOpen = $state(true);
  settingsOpen = $state(false);
  settingsPage = $state("general");
  searchOpen = $state(false);
  mode = $state<"chat" | "agent" | "claw">("chat");
  notice = $state<string | null>(null);
  lastError = $state<string | null>(null);
  /** What the Agent is doing between visible replies (running a tool) — a
   *  transient status line, like the Mac agentActivityText. */
  agentActivity = $state<string | null>(null);
  /** A tool call awaiting the user's go-ahead in Sandboxed mode. */
  pendingToolConfirm = $state<PendingToolConfirm | null>(null);
  /** An agent ask_user question awaiting the user's answer. */
  pendingAgentQuestion = $state<PendingAgentQuestion | null>(null);
  /** The message currently being read aloud, or null when silent. */
  speakingMessageId = $state<string | null>(null);
  /** Live MCP connection state per configured server id. */
  mcpConnections = $state<Record<string, { status: "connecting" | "connected" | "error"; error?: string; tools: McpToolInfo[] }>>({});
  /** Last proxy-apply failure (bad address), shown next to the setting. */
  proxyError = $state<string | null>(null);
  /** The "Check for Updates" flow's state. */
  updateCheckState = $state<
    | { status: "idle" }
    | { status: "checking" }
    | { status: "done"; latestVersion: string; notes: string; url: string }
    | { status: "error"; message: string }
  >({ status: "idle" });
  /** Files/images staged in the composer for the next send. */
  pendingAttachments = $state<MessageAttachment[]>([]);
  /** attachment id → data URL, for composer chips and message thumbnails.
   *  Filled on import; lazily refilled from disk for restored chats. */
  attachmentPreviews = $state<Record<string, string>>({});
  /** Conversations where the user chose "Allow for this chat" — skips further
   *  confirmation for the rest of the conversation. */
  private allowAllConversations = new Set<string>();
  dialog = $state<
    | { kind: "deleteChat"; id: string }
    | { kind: "renameChat"; id: string }
    | { kind: "newProject" }
    | { kind: "renameProject"; id: string }
    | { kind: "deleteProject"; id: string }
    | { kind: "deleteModel"; name: string }
    | null
  >(null);

  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  private loaded = false;

  // ---- Derived --------------------------------------------------------

  get current(): Conversation | null {
    return this.conversations.find((c) => c.id === this.currentId) ?? null;
  }

  get sortedConversations(): Conversation[] {
    return [...this.conversations].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  get pinnedConversations(): Conversation[] {
    return this.sortedConversations.filter((c) => c.isPinned && !c.projectId);
  }

  get unpinnedUnfiledConversations(): Conversation[] {
    return this.sortedConversations.filter((c) => !c.isPinned && !c.projectId);
  }

  get sortedProjects(): Project[] {
    return [...this.projects].sort((a, b) => b.createdAt - a.createdAt);
  }

  conversationsInProject(projectId: string): Conversation[] {
    return this.sortedConversations.filter((c) => c.projectId === projectId);
  }

  get sortedSkills(): Skill[] {
    return [...this.settings.skills].sort((a, b) => a.installedAt - b.installedAt);
  }

  /** What `/` autocomplete offers — a disabled skill is installed but inert. */
  get enabledSkills(): Skill[] {
    return this.settings.skills.filter((s) => s.isEnabled);
  }

  /** Case-insensitive lookup by the hyphenated `/name` form, enabled only. */
  skillNamed(name: string): Skill | null {
    const normalized = normalizeSkillName(name);
    if (!normalized) return null;
    return this.enabledSkills.find((s) => s.name === normalized) ?? null;
  }

  /** Provider-merged catalog: Aqua → BYOK configs → local Ollama. */
  get allModels(): ModelEntry[] {
    const entries: ModelEntry[] = [];
    if (this.settings.aquaApiKey) {
      for (const m of this.aquaModels) {
        entries.push({
          key: `aqua:${m.id}`,
          requestId: m.id,
          display: this.settings.nicknames[`aqua:${m.id}`] ?? m.name ?? EAON_HOSTED_CATALOG[m.id] ?? m.id,
          provider: { kind: "aqua" },
          tier: m.tier,
        });
      }
    }
    for (const config of this.settings.customProviders) {
      for (const id of config.modelIDs) {
        const key = `custom:${config.id}:${id}`;
        entries.push({
          key,
          requestId: id,
          display: this.settings.nicknames[key] ?? id,
          provider: { kind: "custom", configId: config.id, configName: config.displayName },
        });
      }
    }
    for (const m of this.ollamaModels) {
      // Diffusion models can't chat — they're image backends, not picker
      // entries (macOS filters isImageGeneration the same way).
      if (m.capabilities?.includes("image")) continue;
      const key = `ollama:${m.name}`;
      entries.push({
        key,
        requestId: m.name,
        display: this.settings.nicknames[key] ?? m.name,
        provider: { kind: "ollama" },
      });
    }
    return entries;
  }

  get selectedModel(): ModelEntry | null {
    return this.allModels.find((m) => m.key === this.selectedModelKey) ?? null;
  }

  isGenerating(conversationId: string | null): boolean {
    if (!conversationId) return false;
    return this.sessions[conversationId]?.streaming === true;
  }

  get currentIsGenerating(): boolean {
    return this.isGenerating(this.currentId);
  }

  isGeneratingInBackground(id: string): boolean {
    return id !== this.currentId && this.sessions[id]?.streaming === true;
  }

  // ---- Persistence ----------------------------------------------------

  async load(): Promise<void> {
    try {
      const raw = await api.loadAppState();
      if (raw) {
        const parsed = JSON.parse(raw);
        this.conversations = parsed.conversations ?? [];
        this.projects = parsed.projects ?? [];
        this.settings = { ...DEFAULT_SETTINGS, ...(parsed.settings ?? {}) };
        this.statistics = parsed.statistics ?? this.statistics;
        this.selectedModelKey = parsed.selectedModelKey ?? "";
      }
    } catch (e) {
      console.error("load failed", e);
    }
    this.loaded = true;

    let needsSave = false;
    if (!this.settings.skills.length) {
      this.settings.skills = STARTER_SKILLS.map((text) => {
        const parsed = parseSkill(text);
        return { id: uid(), name: parsed.name, summary: parsed.summary, instructions: parsed.instructions, source: { kind: "starter" as const }, isEnabled: true, installedAt: Date.now() };
      });
      needsSave = true;
    }
    if (!this.settings.localServerApiKey) {
      this.settings.localServerApiKey = generateLocalServerKey();
      needsSave = true;
    }
    if (needsSave) this.saveSoon();

    this.applyAppearance();
    void this.applyProxy();
    // Restart the Local API Server if it was left on last session — no-op
    // when the user never turned it on. Awaited-but-not-blocking: models may
    // still be loading, but the upstream list is rebuilt on every apply.
    if (this.settings.localServerEnabled) void this.applyLocalServer();
    // Reconnect enabled MCP plugins — concurrent, best-effort; failures
    // show on the Plugins page rather than blocking launch.
    for (const server of this.settings.mcpServers.filter((s) => s.enabled)) {
      void this.connectMcpServer(server);
    }
  }

  // ---- Network (proxy) ------------------------------------------------

  /** Pushes the proxy setting into the Rust HTTP layer — all outbound
   *  provider/search/image traffic routes through it. Called on load and
   *  whenever the setting changes. */
  async applyProxy(): Promise<void> {
    try {
      const url = this.settings.proxyEnabled ? this.settings.proxyUrl.trim() : null;
      await api.setProxy(url || null);
      this.proxyError = null;
    } catch (e) {
      this.proxyError = e instanceof Error ? e.message : String(e);
    }
  }

  // ---- Read aloud ------------------------------------------------------

  /** Read this message aloud, or stop if it's already the one playing —
   *  mirrors SpeechNarrator (one utterance at a time). */
  toggleSpeak(message: ChatMessage): void {
    if (this.speakingMessageId === message.id) {
      stopSpeaking();
      this.speakingMessageId = null;
      return;
    }
    const text = speakableText(message.content);
    if (!text) return;
    const started = speak(text, () => {
      if (this.speakingMessageId === message.id) this.speakingMessageId = null;
    });
    this.speakingMessageId = started ? message.id : null;
    if (!started) this.notice = "This system has no speech voices available.";
  }

  // ---- Update check ----------------------------------------------------

  /** Checks the same release manifest the Mac app's UpdateChecker reads and
   *  surfaces the latest version + notes. Download stays a manual click —
   *  installers differ per platform, so no silent self-install here. */
  async checkForUpdate(): Promise<void> {
    this.updateCheckState = { status: "checking" };
    try {
      const raw = await api.fetchTextUrl("https://downloads.eaon.dev/update-manifest.json");
      const manifest = JSON.parse(raw);
      const version = String(manifest.latestVersion ?? "").trim();
      if (!version) throw new Error("The update feed came back malformed.");
      this.updateCheckState = {
        status: "done",
        latestVersion: version,
        notes: typeof manifest.releaseNotes === "string" ? manifest.releaseNotes : "",
        url: typeof manifest.downloadURL === "string" ? manifest.downloadURL : "",
      };
    } catch (e) {
      this.updateCheckState = { status: "error", message: e instanceof Error ? e.message : String(e) };
    }
  }

  // ---- Local API Server -------------------------------------------------

  /** Start or stop the loopback OpenAI-compatible server to match the current
   *  settings, rebuilding its model→provider routing from every configured
   *  model (Aqua / Ollama / BYOK). Called on load and whenever a relevant
   *  setting changes. */
  async applyLocalServer(): Promise<void> {
    try {
      if (!this.settings.localServerEnabled) {
        await api.stopLocalServer();
        this.localServerRunning = false;
        this.localServerError = null;
        return;
      }
      // One upstream per distinct (baseUrl, apiKey), listing the models it
      // serves — so a caller's requested model routes to the right provider.
      const byEndpoint = new Map<string, { baseUrl: string; apiKey: string | null; modelIds: string[] }>();
      for (const m of this.allModels) {
        const { baseUrl, apiKey } = this.endpointFor(m);
        if (!baseUrl) continue;
        const key = `${baseUrl}::${apiKey ?? ""}`;
        const entry = byEndpoint.get(key) ?? { baseUrl, apiKey, modelIds: [] };
        if (!entry.modelIds.includes(m.requestId)) entry.modelIds.push(m.requestId);
        byEndpoint.set(key, entry);
      }
      await api.startLocalServer({
        port: this.settings.localServerPort,
        requireKey: this.settings.localServerRequireApiKey,
        apiKey: this.settings.localServerApiKey,
        upstreams: [...byEndpoint.values()],
      });
      this.localServerRunning = true;
      this.localServerError = null;
    } catch (e) {
      this.localServerRunning = false;
      this.localServerError = String(e);
      // Don't leave the toggle showing "on" for a server that didn't bind.
      this.settings.localServerEnabled = false;
    }
    this.saveSoon();
  }

  regenerateLocalServerKey(): void {
    this.settings.localServerApiKey = generateLocalServerKey();
    this.saveSoon();
    if (this.settings.localServerEnabled) void this.applyLocalServer();
  }

  get localServerBaseUrl(): string {
    return `http://127.0.0.1:${this.settings.localServerPort}/v1`;
  }

  saveSoon(): void {
    if (!this.loaded) return;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => {
      const snapshot = JSON.stringify({
        conversations: this.conversations,
        projects: this.projects,
        settings: this.settings,
        statistics: this.statistics,
        selectedModelKey: this.selectedModelKey,
      });
      api.saveAppState(snapshot).catch((e) => console.error("save failed", e));
    }, 400);
  }

  /** Pushes theme/accent/font-size into CSS-variable land. */
  applyAppearance(): void {
    const root = document.documentElement;
    const theme =
      this.settings.theme === "System"
        ? window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
        : this.settings.theme.toLowerCase();
    root.dataset.theme = theme;
    const accent = ACCENT_OPTIONS.find((a) => a.id === this.settings.accentColorId) ?? ACCENT_OPTIONS[0];
    root.style.setProperty("--accent-user", accent.color);
    const px = this.settings.fontSize === "Small" ? 13 : this.settings.fontSize === "Large" ? 17 : 15;
    root.style.setProperty("--message-font-size", `${px}px`);
  }

  // ---- Conversations --------------------------------------------------

  newChat(projectId: string | null = null): void {
    this.currentId = null;
    this.pendingProjectId = projectId;
    this.selection = { kind: "chat" };
    this.notice = null;
    this.lastError = null;
  }

  private pendingProjectId: string | null = null;

  selectConversation(id: string): void {
    if (id === this.currentId) return;
    this.currentId = id;
    const conversation = this.conversations.find((c) => c.id === id);
    if (conversation?.hasUnread) {
      conversation.hasUnread = false;
      this.saveSoon();
    }
    this.selection = { kind: "chat" };
  }

  deleteConversation(id: string): void {
    this.conversations = this.conversations.filter((c) => c.id !== id);
    if (this.currentId === id) this.currentId = null;
    this.saveSoon();
  }

  renameConversation(id: string, title: string): void {
    const conversation = this.conversations.find((c) => c.id === id);
    const trimmed = title.trim();
    if (!conversation || !trimmed) return;
    conversation.title = trimmed;
    this.saveSoon();
  }

  togglePinned(id: string): void {
    const conversation = this.conversations.find((c) => c.id === id);
    if (!conversation) return;
    conversation.isPinned = !conversation.isPinned;
    this.saveSoon();
  }

  deleteAllUnfiled(): void {
    const current = this.conversations.find((c) => c.id === this.currentId);
    if (current && !current.projectId) this.currentId = null;
    this.conversations = this.conversations.filter((c) => c.projectId);
    this.saveSoon();
  }

  // ---- Projects -------------------------------------------------------

  createProject(name: string): Project {
    const project: Project = { id: uid(), name: name.trim() || "New project", createdAt: Date.now() };
    this.projects.push(project);
    this.saveSoon();
    return project;
  }

  renameProject(id: string, name: string): void {
    const project = this.projects.find((p) => p.id === id);
    const trimmed = name.trim();
    if (!project || !trimmed) return;
    project.name = trimmed;
    this.saveSoon();
  }

  /** Deletes the folder; its chats are kept, just un-grouped (Mac parity). */
  deleteProject(id: string): void {
    this.projects = this.projects.filter((p) => p.id !== id);
    for (const conversation of this.conversations) {
      if (conversation.projectId === id) conversation.projectId = null;
    }
    if (this.selection.kind === "project" && this.selection.id === id) {
      this.selection = { kind: "projects" };
    }
    this.saveSoon();
  }

  // ---- Models ---------------------------------------------------------

  async refreshModels(): Promise<void> {
    this.isLoadingModels = true;
    try {
      this.ollamaModels = await api.ollamaTags(this.settings.ollamaBaseUrl);
      this.ollamaReachable = true;
    } catch {
      // Keep the last-known list on a transient failure (Mac parity) —
      // only the reachable flag flips.
      this.ollamaReachable = false;
    }
    if (this.settings.aquaApiKey) {
      try {
        const models = await api.fetchProviderModels(EAON_HOSTED_BASE_URL, this.settings.aquaApiKey);
        this.aquaModels = models
          .filter((m) => (m.modelType ?? "text").toLowerCase() === "text" && EAON_HOSTED_CATALOG[m.id])
          .map((m) => ({ id: m.id, name: m.name ?? EAON_HOSTED_CATALOG[m.id] ?? null, tier: m.tier ?? null }))
          .sort((a, b) => a.id.localeCompare(b.id));
        // Image models come from the live `type` field, not the chat
        // allowlist — a new image model Aqua adds shows up automatically
        // (mirrors AquaImageModels.fetchAvailable).
        this.aquaImageModels = models
          .filter((m) => (m.modelType ?? "").toLowerCase() === "image")
          .map((m) => m.id);
      } catch (e) {
        console.error("aqua models failed", e);
      }
    } else {
      this.aquaModels = [];
      this.aquaImageModels = [];
    }
    this.reconcileSelectedModel();
    this.isLoadingModels = false;
  }

  reconcileSelectedModel(): void {
    const models = this.allModels;
    if (!models.length) {
      this.selectedModelKey = "";
      return;
    }
    if (models.some((m) => m.key === this.selectedModelKey)) return;
    // Prefer a local, non-embedding, non-cloud model as the default.
    const preferred =
      models.find(
        (m) => m.provider.kind === "ollama" && !m.requestId.includes("embed") && !m.requestId.includes("cloud")
      ) ?? models[0];
    this.selectedModelKey = preferred.key;
    this.saveSoon();
  }

  selectModel(key: string): void {
    this.selectedModelKey = key;
    this.saveSoon();
  }

  toggleFavorite(key: string): void {
    const index = this.settings.favorites.indexOf(key);
    if (index >= 0) this.settings.favorites.splice(index, 1);
    else this.settings.favorites.push(key);
    this.saveSoon();
  }

  // ---- Skills -----------------------------------------------------------

  toggleSkill(id: string): void {
    const skill = this.settings.skills.find((s) => s.id === id);
    if (!skill) return;
    skill.isEnabled = !skill.isEnabled;
    this.saveSoon();
  }

  removeSkill(id: string): void {
    this.settings.skills = this.settings.skills.filter((s) => s.id !== id);
    this.saveSoon();
  }

  /** A duplicate `/name` would be ambiguous to invoke, so this refuses rather than silently shadowing. */
  addManualSkill(name: string, summary: string, instructions: string): Skill {
    const normalized = normalizeSkillName(name);
    if (!normalized) throw new Error("Give the skill a name.");
    if (this.settings.skills.some((s) => s.name === normalized)) {
      throw new Error(`A skill named "${normalized}" is already installed — remove or rename it first.`);
    }
    const skill: Skill = { id: uid(), name: normalized, summary, instructions, source: { kind: "manual" }, isEnabled: true, installedAt: Date.now() };
    this.settings.skills.push(skill);
    this.saveSoon();
    return skill;
  }

  /** Installs (or re-installs in place) a skill from a GitHub URL of almost any shape. */
  async addSkillFromGitHub(url: string): Promise<Skill> {
    const candidates = candidateRawURLs(url);
    if (!candidates.length) throw new Error("That doesn't look like a github.com or raw.githubusercontent.com URL.");

    let lastError = new Error("Couldn't find a SKILL.md file there.");
    for (const candidateURL of candidates) {
      try {
        const text = await api.fetchTextUrl(candidateURL);
        const parsed = parseSkill(text);
        const existing = this.settings.skills.find((s) => s.name === parsed.name);
        if (existing) {
          existing.summary = parsed.summary;
          existing.instructions = parsed.instructions;
          existing.source = { kind: "github", url };
          this.saveSoon();
          return existing;
        }
        const skill: Skill = { id: uid(), name: parsed.name, summary: parsed.summary, instructions: parsed.instructions, source: { kind: "github", url }, isEnabled: true, installedAt: Date.now() };
        this.settings.skills.push(skill);
        this.saveSoon();
        return skill;
      } catch (e) {
        lastError = e instanceof Error ? e : new Error(String(e));
      }
    }
    throw lastError;
  }

  /** Every SKILL.md under ~/.claude/skills/ not already in the library. */
  async localClaudeSkillCandidates(): Promise<Array<{ path: string; parsed: ReturnType<typeof parseSkill> }>> {
    const existingNames = new Set(this.settings.skills.map((s) => s.name));
    const files = await api.scanClaudeSkills();
    const candidates: Array<{ path: string; parsed: ReturnType<typeof parseSkill> }> = [];
    for (const file of files) {
      try {
        const parsed = parseSkill(file.text);
        if (!existingNames.has(parsed.name)) candidates.push({ path: file.path, parsed });
      } catch {
        // Skip anything that doesn't parse — same as the Mac app.
      }
    }
    return candidates;
  }

  importLocalSkill(candidate: { path: string; parsed: ReturnType<typeof parseSkill> }): void {
    if (this.settings.skills.some((s) => s.name === candidate.parsed.name)) return;
    const skill: Skill = {
      id: uid(), name: candidate.parsed.name, summary: candidate.parsed.summary, instructions: candidate.parsed.instructions,
      source: { kind: "localImport", path: candidate.path }, isEnabled: true, installedAt: Date.now(),
    };
    this.settings.skills.push(skill);
    this.saveSoon();
  }

  // ---- Attachments ----------------------------------------------------

  /** Imports a picked/pasted file into the composer's staging row. */
  async addAttachment(file: File): Promise<void> {
    try {
      const { attachment, previewDataUrl } = await importFile(file);
      this.pendingAttachments.push(attachment);
      if (previewDataUrl) this.attachmentPreviews[attachment.id] = previewDataUrl;
    } catch (e) {
      this.notice = `Could not add attachment: ${e instanceof Error ? e.message : e}`;
    }
  }

  removePendingAttachment(id: string): void {
    this.pendingAttachments = this.pendingAttachments.filter((a) => a.id !== id);
  }

  /** Thumbnail data URL for an image attachment on a (possibly restored)
   *  message — cached after the first disk read. */
  async attachmentPreview(attachment: MessageAttachment): Promise<string | null> {
    if (attachment.kind !== "image") return null;
    const cached = this.attachmentPreviews[attachment.id];
    if (cached) return cached;
    try {
      const base64 = await api.readAttachment(attachment.storedFileName);
      const url = `data:${attachment.mimeType};base64,${base64}`;
      this.attachmentPreviews[attachment.id] = url;
      return url;
    } catch {
      return null;
    }
  }

  /** The request history for a conversation — per message, real image parts
   *  when the model has vision, "[Attached: …]" notes otherwise (the split
   *  ChatViewModel.historyTurn makes). */
  private async wireHistory(conversation: Conversation, model: ModelEntry): Promise<api.WireMessage[]> {
    const out: api.WireMessage[] = [];
    for (const m of conversation.messages) {
      const role = m.isToolResult ? "user" : m.role;
      if (m.attachments?.length) {
        out.push({ role, content: await buildContent(m.content, m.attachments, model.requestId) });
      } else {
        out.push({ role, content: m.content });
      }
    }
    return out;
  }

  // ---- MCP plugins ----------------------------------------------------

  /** Connect one configured server (initialize + tools/list) and record its
   *  live tool catalog. Errors land in the connection state, not thrown. */
  async connectMcpServer(server: McpServer): Promise<void> {
    this.mcpConnections[server.id] = { status: "connecting", tools: [] };
    try {
      const tools = await api.mcpConnect({
        id: server.id,
        transport: server.transport,
        url: server.url.trim() || undefined,
        authScheme: server.authScheme.trim() || undefined,
        token: server.token.trim() || undefined,
        command: server.command.trim() || undefined,
        args: server.args.trim() ? server.args.trim().split(/\s+/) : [],
      });
      this.mcpConnections[server.id] = { status: "connected", tools };
    } catch (e) {
      this.mcpConnections[server.id] = { status: "error", error: e instanceof Error ? e.message : String(e), tools: [] };
    }
  }

  async disconnectMcpServer(id: string): Promise<void> {
    try {
      await api.mcpDisconnect(id);
    } catch {
      // Best-effort — the registry entry is gone either way.
    }
    delete this.mcpConnections[id];
  }

  removeMcpServer(id: string): void {
    void this.disconnectMcpServer(id);
    this.settings.mcpServers = this.settings.mcpServers.filter((s) => s.id !== id);
    this.saveSoon();
  }

  /** Every enabled server that's actually connected with tools, for the
   *  system-prompt catalog. */
  private get connectedMcpEntries(): Array<{ server: McpServer; tools: McpToolInfo[] }> {
    return this.settings.mcpServers
      .filter((s) => s.enabled)
      .map((server) => ({ server, tools: this.mcpConnections[server.id]?.status === "connected" ? this.mcpConnections[server.id].tools : [] }))
      .filter((e) => e.tools.length > 0);
  }

  /** Executes one reply's eaon:mcp calls (with Sandboxed confirmation) and
   *  returns their result sections — shared by the chat and agent loops. */
  private async executeMcpCalls(conversationId: string, calls: McpCall[]): Promise<string[]> {
    const sections: string[] = [];
    for (const call of calls) {
      if (this.sessions[conversationId]?.stopped) break;
      const label = `${call.serverId} › ${call.tool}`;
      const connection = this.mcpConnections[call.serverId];
      if (!connection || connection.status !== "connected") {
        sections.push(`### ${label}\nERROR: "${call.serverId}" is not a connected service — the connected server ids are exactly: ${Object.keys(this.mcpConnections).join(", ") || "(none)"}.`);
        continue;
      }
      if (call.parseError) {
        const tool = connection.tools.find((t) => t.name === call.tool);
        sections.push(`### ${label}\nERROR: the block body wasn't valid JSON. ${tool ? detailedSpec(tool) : ""}`);
        continue;
      }
      if (!this.settings.alwaysAllowTools && !this.allowAllConversations.has(conversationId)) {
        // A direct confirmation (not confirmTool) so the dialog shows the
        // real service+tool and the FULL argument JSON — a live account
        // action never hides behind a tidy one-liner.
        const decision = await new Promise<"once" | "always" | "deny">((resolve) => {
          this.pendingToolConfirm = {
            summary: `Call ${call.tool} on ${call.serverId}`,
            detail: JSON.stringify(call.args, null, 2),
            resolve: (d) => {
              this.pendingToolConfirm = null;
              resolve(d);
            },
          };
        });
        if (decision === "deny") {
          sections.push(`### ${label}\nSkipped — you didn't allow this action.`);
          continue;
        }
        if (decision === "always") this.allowAllConversations.add(conversationId);
      }
      this.agentActivity = `Calling ${label}…`;
      try {
        const result = await api.mcpCall(call.serverId, call.tool, call.args);
        if (result.isError) {
          const tool = connection.tools.find((t) => t.name === call.tool);
          sections.push(`### ${label}\nERROR: ${result.text}${tool ? `\n${detailedSpec(tool)}` : ""}`);
        } else {
          sections.push(`### ${label}\n${result.text}`);
        }
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        const tool = connection.tools.find((t) => t.name === call.tool);
        sections.push(`### ${label}\nERROR: ${message}${tool ? `\n${detailedSpec(tool)}` : ""}`);
      }
      this.agentActivity = null;
    }
    return sections;
  }

  // ---- Image generation ----------------------------------------------

  /** Whether ANY image backend is configured/available — gates both the
   *  teaching block and fence execution (mirrors resolveBackend). */
  get hasImageBackend(): boolean {
    if (this.settings.imageProviders.length) return true;
    if (this.ollamaModels.some((m) => m.capabilities?.includes("image"))) return true;
    return this.aquaImageModels.length > 0 && !!this.settings.aquaApiKey;
  }

  /** Generates one image via the first configured backend, saves it through
   *  the attachments store, and returns the attachment. Backend priority is
   *  the Mac app's: BYOK image provider → local Ollama diffusion model →
   *  Aqua's hosted image models. */
  async generateImageAttachment(prompt: string): Promise<MessageAttachment> {
    let result: api.ImageGenResult;
    const provider = this.settings.imageProviders[0];
    const ollamaImage = this.ollamaModels.find((m) => m.capabilities?.includes("image"));
    if (provider) {
      result = await api.generateImage({
        format: provider.format,
        baseUrl: provider.baseURL,
        model: provider.modelIDs[0] ?? "",
        prompt,
        apiKey: provider.apiKey || null,
      });
    } else if (ollamaImage) {
      result = await api.generateImage({
        format: "ollama",
        baseUrl: this.settings.ollamaBaseUrl,
        model: ollamaImage.name,
        prompt,
        apiKey: null,
      });
    } else if (this.aquaImageModels.length && this.settings.aquaApiKey) {
      result = await api.generateImage({
        format: "aqua",
        baseUrl: EAON_HOSTED_BASE_URL,
        model: this.aquaImageModels[0],
        prompt,
        apiKey: this.settings.aquaApiKey,
      });
    } else {
      throw new Error("No image backend is set up — add one in Settings → Image Providers.");
    }

    const stored = await api.saveAttachment(result.dataBase64, result.suggestedFileName);
    const attachment: MessageAttachment = {
      id: uid(),
      fileName: result.suggestedFileName,
      kind: "image",
      storedFileName: stored,
      mimeType: "image/png",
    };
    this.attachmentPreviews[attachment.id] = `data:image/png;base64,${result.dataBase64}`;
    return attachment;
  }

  /** After a completed reply: execute any eaon:image fences the model
   *  emitted — generate, attach to that same assistant message, strip the
   *  plumbing from the visible text. Failures land as a short note instead
   *  of a broken fence. */
  private async resolveImageFences(assistant: ChatMessage): Promise<void> {
    if (!this.settings.imageToolEnabled) return;
    const prompts = parseImagePrompts(assistant.content).slice(0, 3);
    if (!prompts.length) return;

    const attachments: MessageAttachment[] = [];
    let failure: string | null = null;
    for (const prompt of prompts) {
      this.agentActivity = "Generating image…";
      try {
        attachments.push(await this.generateImageAttachment(prompt));
      } catch (e) {
        failure = e instanceof Error ? e.message : String(e);
      }
    }
    this.agentActivity = null;

    assistant.content = stripImageFences(assistant.content);
    if (attachments.length) {
      assistant.attachments = [...(assistant.attachments ?? []), ...attachments];
      if (!assistant.content) assistant.content = "Here you go.";
    }
    if (failure) {
      assistant.content = assistant.content
        ? `${assistant.content}\n\n*Image generation failed: ${failure}*`
        : `Image generation failed: ${failure}`;
    }
    this.saveSoon();
  }

  // ---- Sending --------------------------------------------------------

  /** The OpenAI sampling fields to send — only what the user switched on;
   *  null when nothing is (so the request is byte-identical to before the
   *  feature existed). Mirrors ModelParametersStore.effectiveParameters. */
  private get samplingFields(): Record<string, number> | null {
    const p = this.settings.modelParams;
    const fields: Record<string, number> = {};
    if (p.temperatureEnabled) fields.temperature = p.temperature;
    if (p.topPEnabled) fields.top_p = p.topP;
    if (p.maxTokensEnabled) fields.max_tokens = p.maxTokens;
    if (p.frequencyPenaltyEnabled) fields.frequency_penalty = p.frequencyPenalty;
    if (p.presencePenaltyEnabled) fields.presence_penalty = p.presencePenalty;
    return Object.keys(fields).length ? fields : null;
  }

  private endpointFor(model: ModelEntry): { baseUrl: string; apiKey: string | null } {
    switch (model.provider.kind) {
      case "aqua":
        return { baseUrl: EAON_HOSTED_BASE_URL, apiKey: this.settings.aquaApiKey };
      case "ollama":
        return { baseUrl: `${this.settings.ollamaBaseUrl}/v1`, apiKey: null };
      case "custom": {
        const configId = model.provider.configId;
        const config = this.settings.customProviders.find((c) => c.id === configId);
        return { baseUrl: config?.baseURL ?? "", apiKey: config?.apiKey ?? null };
      }
    }
  }

  /**
   * Detects a leading `/skill-name` in the user's raw input. The name must
   * be installed AND enabled, otherwise this is just an ordinary message
   * that happens to start with a slash. Returns the matched skill and the
   * text with that leading token removed; if the skill consumed the whole
   * message, a short generic fallback stands in so the turn still sends
   * something.
   */
  private extractSkillInvocation(text: string): { skill: Skill | null; text: string } {
    if (!text.startsWith("/")) return { skill: null, text };
    const withoutSlash = text.slice(1);
    const spaceIndex = withoutSlash.search(/\s/);
    const name = spaceIndex === -1 ? withoutSlash : withoutSlash.slice(0, spaceIndex);
    const skill = name ? this.skillNamed(name) : null;
    if (!skill) return { skill: null, text };
    const rest = (spaceIndex === -1 ? "" : withoutSlash.slice(spaceIndex)).trim();
    return { skill, text: rest || `Use the "${skill.name}" skill.` };
  }

  async send(rawText: string): Promise<void> {
    const { skill: invokedSkill, text } = this.extractSkillInvocation(rawText.trim());
    const trimmed = text.trim();
    const model = this.selectedModel;
    const attachments = this.pendingAttachments;
    // A message can be text, attachments, or both — same rule as the Mac
    // composer's `(!text.isEmpty || !attachments.isEmpty)`.
    if ((!trimmed && !attachments.length) || !model) return;
    if (this.currentIsGenerating) return;
    this.pendingAttachments = [];

    const titleSeed = trimmed || attachments.map((a) => a.fileName).join(", ");

    // Resolve (or create) the conversation, then capture the REFERENCE —
    // everything below writes through it, so switching away mid-stream
    // can't redirect this generation's output (Mac-parity concurrency).
    let conversation = this.current;
    if (!conversation) {
      conversation = {
        id: uid(),
        title: deriveTitle(titleSeed),
        messages: [],
        createdAt: Date.now(),
        updatedAt: Date.now(),
        projectId: this.pendingProjectId,
      };
      this.pendingProjectId = null;
      this.conversations.push(conversation);
      this.currentId = conversation.id;
    }
    const conversationId = conversation.id;

    conversation.messages.push({
      id: uid(), role: "user", content: trimmed, reasoning: "", timestamp: Date.now(),
      invokedSkillName: invokedSkill?.name,
      attachments: attachments.length ? attachments : undefined,
    });
    if (conversation.title === "New chat") conversation.title = deriveTitle(titleSeed);
    conversation.updatedAt = Date.now();

    // System entries: the user's custom instructions, the Agent teaching
    // block (Agent mode only), then a one-off /skill invocation — freshest
    // last, right before the actual conversation.
    const baseSystem: Array<{ role: string; content: string }> = [];
    const instructions = this.settings.customInstructions.trim();
    if (instructions) baseSystem.push({ role: "system", content: instructions });
    // Remembered facts about the user — context, injected after the user's
    // own directives.
    if (this.settings.memoryEnabled && this.settings.memories.length) {
      baseSystem.push({ role: "system", content: memoryBlock(this.settings.memories) });
    }
    if (this.mode === "agent") {
      baseSystem.push({ role: "system", content: agentInstruction(this.settings.deviceControlEnabled) });
    }
    // Web search teaching (with the real device clock) — on unless the user
    // turned it off, mirroring WebSearchStore's default-on.
    if (this.settings.webSearchEnabled) {
      baseSystem.push({ role: "system", content: searchInstruction() });
    }
    // Image tool teaching — only when the toggle is on AND a backend
    // actually exists, so the model is never taught a tool that can't run.
    if (this.settings.imageToolEnabled && this.hasImageBackend) {
      baseSystem.push({ role: "system", content: IMAGE_INSTRUCTION });
    }
    // Connected plugins' live tool catalog — nil when nothing usable is
    // connected, so the block never teaches tools that can't run.
    const mcpBlock = mcpInstructionBlock(this.connectedMcpEntries);
    if (mcpBlock) baseSystem.push({ role: "system", content: mcpBlock });
    if (invokedSkill) {
      baseSystem.push({
        role: "system",
        content: `The user has explicitly invoked the "${invokedSkill.name}" skill for this request — follow its instructions:\n\n${invokedSkill.instructions}`,
      });
    }

    const requestId = requestCounter++;
    this.sessions[conversationId] = { requestId, streaming: true };
    this.statistics.promptsSent += 1;
    const perModel = (this.statistics.perModel[model.key] ??= { prompts: 0, chars: 0 });
    perModel.prompts += 1;
    this.lastError = null;
    this.saveSoon();

    try {
      if (this.mode === "agent") {
        await this.runAgentLoop(conversation, conversationId, model, perModel, baseSystem);
      } else {
        // Plain chat still loops on eaon:search / eaon:mcp fences — the
        // model searches or calls a plugin, reads the results, and
        // continues, exactly like the Mac executeAgentTools round-trip
        // (capped so a confused model can't spin forever).
        const MAX_TOOL_ROUNDS = 4;
        const history = [...baseSystem, ...(await this.wireHistory(conversation, model))];
        let assistant: ChatMessage | null = null;
        for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
          assistant = await this.streamStep(conversation, conversationId, model, perModel, history);
          if (assistant.isError || this.sessions[conversationId]?.stopped) break;

          const queries = this.settings.webSearchEnabled ? parseSearchQueries(assistant.content).slice(0, 3) : [];
          const mcpCalls = parseMcpCalls(assistant.content).slice(0, 5);
          if (!queries.length && !mcpCalls.length) break;

          history.push({ role: "assistant", content: assistant.content });
          assistant.content = stripMcpFences(stripSearchFences(assistant.content));
          if (!assistant.content && !assistant.reasoning) {
            // The reply was nothing but the tool call — drop the empty
            // bubble; the results card and the follow-up reply tell the story.
            conversation.messages = conversation.messages.filter((m) => m.id !== assistant!.id);
          }

          const sections: string[] = [];
          for (const query of queries) {
            this.agentActivity = `Searching the web: ${query}`;
            try {
              const hits = await api.webSearch(query);
              sections.push(`### web_search: ${query}\n${formatSearchResults(hits)}`);
            } catch (e) {
              sections.push(`### web_search: ${query}\nERROR: ${e instanceof Error ? e.message : e}`);
            }
          }
          this.agentActivity = null;
          sections.push(...(await this.executeMcpCalls(conversationId, mcpCalls)));
          if (this.sessions[conversationId]?.stopped) break;

          const resultsText = `[Tool results — automated, not written by the user]\n\n${sections.join("\n\n")}`;
          conversation.messages.push({
            id: uid(), role: "user", content: resultsText, reasoning: "",
            timestamp: Date.now(), isToolResult: true,
          });
          history.push({ role: "user", content: resultsText });
          this.saveSoon();
        }

        if (assistant && !assistant.isError) {
          // The model may also have asked for an image (eaon:image fence) —
          // generate and attach it before anything else reads the reply.
          await this.resolveImageFences(assistant);
          // Silently learn durable facts from this exchange —
          // fire-and-forget, never blocks the reply.
          if (this.settings.memoryEnabled && assistant.content.trim()) {
            void this.extractMemories(trimmed, assistant.content, model);
          }
        }
      }
    } finally {
      delete this.sessions[conversationId];
      this.agentActivity = null;
      conversation.updatedAt = Date.now();
      if (conversationId !== this.currentId) conversation.hasUnread = true;
      this.saveSoon();
    }
  }

  // ---- Memory ----------------------------------------------------------

  /** Background fact-extraction from one exchange — one non-streaming model
   *  call, deduped against what's already known, appended to settings.memories.
   *  Best-effort: any failure is swallowed (personalization is never worth an
   *  error in the user's face). Ports MemoryExtractor.run. */
  private async extractMemories(userText: string, assistantText: string, model: ModelEntry): Promise<void> {
    try {
      const existing = this.settings.memories.map((m) => m.text);
      const { baseUrl, apiKey } = this.endpointFor(model);
      if (!baseUrl) return;
      const raw = await api.chatComplete({
        baseUrl,
        apiKey,
        model: model.requestId,
        messages: [
          { role: "system", content: MEMORY_SYSTEM_PROMPT },
          { role: "user", content: buildExtractionPrompt(userText, assistantText, existing) },
        ],
      });
      const seen = new Set(this.settings.memories.map((m) => memoryKey(m.text)));
      let added = false;
      for (const item of parseExtraction(raw)) {
        const key = memoryKey(item.text);
        if (seen.has(key)) continue;
        seen.add(key);
        this.settings.memories.push({ id: uid(), text: item.text, kind: item.kind, createdAt: Date.now() });
        added = true;
      }
      if (added) this.saveSoon();
    } catch {
      // Personalization is best-effort — never surface a failure.
    }
  }

  addManualMemory(text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    const key = memoryKey(trimmed);
    if (this.settings.memories.some((m) => memoryKey(m.text) === key)) return;
    this.settings.memories.push({ id: uid(), text: trimmed, kind: "fact", createdAt: Date.now() });
    this.saveSoon();
  }

  removeMemory(id: string): void {
    this.settings.memories = this.settings.memories.filter((m) => m.id !== id);
    this.saveSoon();
  }

  clearMemories(): void {
    this.settings.memories = [];
    this.saveSoon();
  }

  get sortedMemories(): Memory[] {
    return [...this.settings.memories].sort((a, b) => b.createdAt - a.createdAt);
  }

  /** One streamed assistant reply into a fresh message. Shared by plain chat
   *  and each step of the Agent loop. Returns the completed message. */
  private async streamStep(
    conversation: Conversation,
    conversationId: string,
    model: ModelEntry,
    perModel: { prompts: number; chars: number },
    history: api.WireMessage[]
  ): Promise<ChatMessage> {
    const assistant: ChatMessage = {
      id: uid(), role: "assistant", content: "", reasoning: "",
      modelId: model.key, modelDisplay: model.display,
      timestamp: Date.now(), generationStartTime: Date.now(),
    };
    conversation.messages.push(assistant);

    const requestId = requestCounter++;
    const session = this.sessions[conversationId];
    if (session) session.requestId = requestId; // so stopGeneration cancels this step

    const { baseUrl, apiKey } = this.endpointFor(model);
    try {
      await api.chatStream({
        baseUrl, apiKey, model: model.requestId, messages: history, requestId,
        sampling: this.samplingFields,
        onEvent: (event) => {
          if (event.type === "token") {
            assistant.content += event.text;
            this.statistics.charsGenerated += event.text.length;
            perModel.chars += event.text.length;
          } else if (event.type === "reasoning") {
            assistant.reasoning += event.text;
          } else if (event.type === "error") {
            assistant.isError = true;
            assistant.content = assistant.content || event.message;
            if (conversationId === this.currentId) this.lastError = event.message;
          }
        },
      });
    } catch (e) {
      if (!assistant.isError) {
        assistant.isError = true;
        assistant.content = assistant.content || String(e);
        if (conversationId === this.currentId) this.lastError = String(e);
      }
    } finally {
      assistant.generationEndTime = Date.now();
      assistant.generatedTokenCount = Math.max(1, Math.ceil(assistant.content.length / 4));
    }
    return assistant;
  }

  /** The Agent's multi-step loop: stream → run any tool calls → feed the
   *  results back → repeat, until the reply has no tool calls or a step cap.
   *  Ports ChatViewModel's agent loop. */
  private async runAgentLoop(
    conversation: Conversation,
    conversationId: string,
    model: ModelEntry,
    perModel: { prompts: number; chars: number },
    baseSystem: Array<{ role: string; content: string }>
  ): Promise<void> {
    const MAX_STEPS = 25;
    const history: api.WireMessage[] = [...baseSystem, ...(await this.wireHistory(conversation, model))];

    for (let step = 0; step < MAX_STEPS; step++) {
      if (this.sessions[conversationId]?.stopped) break;
      const assistant = await this.streamStep(conversation, conversationId, model, perModel, history);
      if (assistant.isError || this.sessions[conversationId]?.stopped) break;
      history.push({ role: "assistant", content: assistant.content });

      const calls = parseToolCalls(assistant.content);
      const mcpCalls = parseMcpCalls(assistant.content).slice(0, 5);
      if (calls.length === 0 && mcpCalls.length === 0) break; // no tool calls → the turn is finished

      const sections: string[] = [];
      for (const call of calls) {
        if (this.sessions[conversationId]?.stopped) break;
        // ask_user pauses the loop on a real dialog and the answer goes
        // back as the tool result — never executed as a system action.
        if (call.name === "ask_user") {
          const question = String(call.args.question ?? "").trim();
          const options = Array.isArray(call.args.options)
            ? call.args.options.map(String).filter(Boolean).slice(0, 4)
            : [];
          if (!question) {
            sections.push(`### ask_user\nERROR: ask_user needs a "question".`);
            continue;
          }
          const answer = await this.askAgentQuestion(question, options);
          sections.push(`### ask_user\nThe user answered: ${answer}`);
          continue;
        }
        // Device tools (formerly Eaon Claw) only exist while the user has
        // device control switched on — refused at execution time too, in
        // case a model emits one unprompted.
        if (DEVICE_TOOLS.has(call.name) && !this.settings.deviceControlEnabled) {
          sections.push(`### ${call.name}\nERROR: device control is turned off in Settings → Eaon Claw.`);
          continue;
        }
        if (
          !isReadOnlyTool(call.name) &&
          !this.settings.alwaysAllowTools &&
          !this.allowAllConversations.has(conversationId)
        ) {
          const decision = await this.confirmTool(call);
          if (decision === "deny") {
            sections.push(`### ${call.name}\nSkipped — you didn't allow this action.`);
            continue;
          }
          if (decision === "always") this.allowAllConversations.add(conversationId);
        }
        this.agentActivity = `Running ${call.name}…`;
        const outcome = await runTool(call);
        this.agentActivity = null;
        sections.push(`### ${call.name}\n${outcome.ok ? "OK" : "ERROR"}:\n${outcome.text}`);
      }
      sections.push(...(await this.executeMcpCalls(conversationId, mcpCalls)));

      if (this.sessions[conversationId]?.stopped) break;
      const resultsText = `[Tool results — automated, not written by the user]\n\n${sections.join("\n\n")}`;
      conversation.messages.push({
        id: uid(), role: "user", content: resultsText, reasoning: "",
        timestamp: Date.now(), isToolResult: true,
      });
      history.push({ role: "user", content: resultsText });
      this.saveSoon();
    }
  }

  /** Pauses on a confirmation dialog and resolves with the user's decision —
   *  the promise the Agent loop awaits in Sandboxed mode. */
  private confirmTool(call: ToolCall): Promise<"once" | "always" | "deny"> {
    return new Promise((resolve) => {
      this.pendingToolConfirm = {
        summary: toolSummary(call),
        detail: toolDetail(call),
        resolve: (decision) => {
          this.pendingToolConfirm = null;
          resolve(decision);
        },
      };
    });
  }

  /** Pauses on the agent's question dialog (ask_user) and resolves with the
   *  user's answer — an option click or their own typed text. */
  private askAgentQuestion(question: string, options: string[]): Promise<string> {
    return new Promise((resolve) => {
      this.pendingAgentQuestion = {
        question,
        options,
        resolve: (answer) => {
          this.pendingAgentQuestion = null;
          resolve(answer);
        },
      };
    });
  }

  respondToToolConfirm(decision: "once" | "always" | "deny"): void {
    this.pendingToolConfirm?.resolve(decision);
  }

  stopGeneration(): void {
    const id = this.currentId;
    if (!id) return;
    const session = this.sessions[id];
    if (session) {
      session.stopped = true;
      api.cancelStream(session.requestId);
    }
    // Unblock a paused tool-confirmation or agent question so the loop can
    // exit.
    this.pendingToolConfirm?.resolve("deny");
    this.pendingAgentQuestion?.resolve("(the user stopped the run)");
  }

  async regenerate(): Promise<void> {
    const conversation = this.current;
    if (!conversation || this.currentIsGenerating) return;
    // Drop the trailing assistant reply, re-send the last user message.
    const lastUserIndex = conversation.messages.findLastIndex((m) => m.role === "user");
    if (lastUserIndex === -1) return;
    const text = conversation.messages[lastUserIndex].content;
    conversation.messages = conversation.messages.slice(0, lastUserIndex);
    await this.send(text);
  }

  // ---- Ollama pulls ---------------------------------------------------

  async pullModel(name: string): Promise<void> {
    if (this.pulls[name]) return;
    this.pulls[name] = { status: "starting…", completed: 0, total: 0 };
    try {
      await api.ollamaPull(this.settings.ollamaBaseUrl, name, (event) => {
        if (event.type === "progress") {
          this.pulls[name] = { status: event.status, completed: event.completed, total: event.total };
        } else if (event.type === "error") {
          this.pulls[name] = { ...this.pulls[name], error: event.message };
        }
      });
      delete this.pulls[name];
      await this.refreshModels();
    } catch (e) {
      this.pulls[name] = { status: "failed", completed: 0, total: 0, error: String(e) };
    }
  }

  dismissPullError(name: string): void {
    delete this.pulls[name];
  }

  /** Verified deletion — surfaces the real reason if disk wasn't freed. */
  async deleteModel(name: string): Promise<string | null> {
    try {
      await api.ollamaDelete(this.settings.ollamaBaseUrl, name);
      await this.refreshModels();
      return null;
    } catch (e) {
      return String(e);
    }
  }
}

export const app = new AppState();
