<script lang="ts">
  // Port of SettingsRootView.swift — centered 980×700 floating card
  // (clamped to the window with a 24px margin, the same responsive fix the
  // Mac app just got), 230px category sidebar with BETA pills and the
  // MODEL PROVIDERS section, content pane per page.
  import { app, ACCENT_OPTIONS, EAON_HOSTED_BASE_URL } from "$lib/state.svelte";
  import type { CustomProvider, FontSizeChoice, ImageProvider, ImageWireFormat, McpServer, Skill, ThemeChoice } from "$lib/types";
  import { MCP_PRESETS } from "$lib/mcp";
  import { formatBytes, modKeyLabel, uid } from "$lib/utils";
  import Icon from "./Icon.svelte";
  import Switch from "./Switch.svelte";

  const CATEGORIES: Array<{ id: string; title: string; icon: string; beta?: boolean }> = [
    { id: "general", title: "General", icon: "gear" },
    { id: "instructions", title: "Custom Instructions", icon: "text-quote" },
    { id: "memory", title: "Memory", icon: "brain" },
    { id: "plugins", title: "Plugins", icon: "puzzle" },
    { id: "skills", title: "Skills", icon: "bolt", beta: true },
    { id: "imageProviders", title: "Image Providers", icon: "photo" },
    { id: "modelParams", title: "Model Parameters", icon: "sliders" },
    { id: "computer", title: "Eaon Claw", icon: "desktop", beta: true },
    { id: "localServer", title: "Local API Server", icon: "server", beta: true },
    { id: "appearance", title: "Appearance", icon: "paint" },
    { id: "shortcuts", title: "Shortcuts", icon: "keyboard" },
    { id: "privacy", title: "Privacy", icon: "lock" },
    { id: "statistics", title: "Statistics", icon: "chart" },
    { id: "hardware", title: "Hardware", icon: "cpu" },
  ];

  const COMING_SOON: Record<string, { title: string; blurb: string; beta?: boolean }> = {};

  // ---- Plugins (MCP) page state ----
  let editingMcp = $state<McpServer | null>(null);
  let mcpName = $state("");
  let mcpTransport = $state<"http" | "stdio">("http");
  let mcpUrl = $state("");
  let mcpScheme = $state("Bearer");
  let mcpToken = $state("");
  let mcpCommand = $state("");
  let mcpArgs = $state("");

  function startMcpServer(preset?: { name: string; url: string; authScheme: string }) {
    editingMcp = {
      id: uid(), name: preset?.name ?? "", transport: "http",
      url: preset?.url ?? "", authScheme: preset?.authScheme ?? "Bearer",
      token: "", command: "", args: "", enabled: true,
    };
    mcpName = preset?.name ?? "";
    mcpTransport = "http";
    mcpUrl = preset?.url ?? "";
    mcpScheme = preset?.authScheme ?? "Bearer";
    mcpToken = ""; mcpCommand = ""; mcpArgs = "";
  }

  function startEditMcpServer(server: McpServer) {
    editingMcp = server;
    mcpName = server.name;
    mcpTransport = server.transport;
    mcpUrl = server.url;
    mcpScheme = server.authScheme;
    mcpToken = server.token;
    mcpCommand = server.command;
    mcpArgs = server.args;
  }

  function saveMcpServer() {
    if (!editingMcp) return;
    const config: McpServer = {
      id: editingMcp.id,
      name: mcpName.trim() || (mcpTransport === "http" ? "MCP server" : mcpCommand.trim().split(/\s+/)[0] || "Local server"),
      transport: mcpTransport,
      url: mcpUrl.trim(),
      authScheme: mcpScheme.trim() || "Bearer",
      token: mcpToken.trim(),
      command: mcpCommand.trim(),
      args: mcpArgs.trim(),
      enabled: true,
    };
    const index = app.settings.mcpServers.findIndex((s) => s.id === config.id);
    if (index >= 0) app.settings.mcpServers[index] = config;
    else app.settings.mcpServers.push(config);
    editingMcp = null;
    app.saveSoon();
    void app.connectMcpServer(config);
  }

  function toggleMcpServer(server: McpServer) {
    server.enabled = !server.enabled;
    app.saveSoon();
    if (server.enabled) void app.connectMcpServer(server);
    else void app.disconnectMcpServer(server.id);
  }

  const CLAW_CAPABILITIES: Array<[string, string]> = [
    ["Move to trash", "Recoverable — never a permanent delete, and Eaon is told never to route around it."],
    ["Open & quit apps", "Launch or close an application by name."],
    ["Open URLs", "Open a page in your default browser (http/https only)."],
    ["Open files & folders", "Open anything with its default app, or show it in the file manager."],
  ];

  // ---- Image Providers page state ----
  let editingImageProvider = $state<ImageProvider | null>(null);
  let imgName = $state("");
  let imgBase = $state("");
  let imgKey = $state("");
  let imgModels = $state("");
  let imgFormat = $state<ImageWireFormat>("openai");

  function startImageProvider(config: ImageProvider | null) {
    editingImageProvider = config ?? { id: uid(), displayName: "", baseURL: "", format: "openai", apiKey: "", modelIDs: [] };
    imgName = config?.displayName ?? "";
    imgBase = config?.baseURL ?? "";
    imgKey = config?.apiKey ?? "";
    imgModels = (config?.modelIDs ?? []).join("\n");
    imgFormat = config?.format ?? "openai";
  }

  function saveImageProvider() {
    if (!editingImageProvider) return;
    const config: ImageProvider = {
      id: editingImageProvider.id,
      displayName: imgName.trim() || (imgFormat === "automatic1111" ? "Local image server" : "Image provider"),
      baseURL: imgBase.trim().replace(/\/$/, ""),
      format: imgFormat,
      apiKey: imgKey.trim(),
      modelIDs: imgModels.split("\n").map((s) => s.trim()).filter(Boolean),
    };
    const index = app.settings.imageProviders.findIndex((c) => c.id === config.id);
    if (index >= 0) app.settings.imageProviders[index] = config;
    else app.settings.imageProviders.push(config);
    editingImageProvider = null;
    app.saveSoon();
  }

  function deleteImageProvider(id: string) {
    app.settings.imageProviders = app.settings.imageProviders.filter((c) => c.id !== id);
    app.saveSoon();
  }

  // ---- Skills page state ----
  type SkillAddMode = null | "github" | "manual" | "local";
  let skillAddMode = $state<SkillAddMode>(null);
  let skillGithubUrl = $state("");
  let skillInstalling = $state(false);
  let skillError = $state<string | null>(null);
  let skillName = $state("");
  let skillSummary = $state("");
  let skillInstructions = $state("");
  let localSkillCandidates = $state<Array<{ path: string; parsed: { name: string; summary: string; instructions: string } }> | null>(null);
  let importedSkillPaths = $state<Set<string>>(new Set());

  function openSkillAdd(mode: SkillAddMode) {
    skillAddMode = skillAddMode === mode ? null : mode;
    skillError = null;
    if (skillAddMode === "local") {
      localSkillCandidates = null;
      importedSkillPaths = new Set();
      app.localClaudeSkillCandidates().then((found) => (localSkillCandidates = found));
    }
  }

  async function installSkillFromGitHub() {
    const url = skillGithubUrl.trim();
    if (!url || skillInstalling) return;
    skillError = null;
    skillInstalling = true;
    try {
      await app.addSkillFromGitHub(url);
      skillGithubUrl = "";
      skillAddMode = null;
    } catch (e) {
      skillError = e instanceof Error ? e.message : String(e);
    } finally {
      skillInstalling = false;
    }
  }

  function saveManualSkill() {
    skillError = null;
    try {
      app.addManualSkill(skillName.trim(), skillSummary.trim(), skillInstructions.trim());
      skillName = ""; skillSummary = ""; skillInstructions = "";
      skillAddMode = null;
    } catch (e) {
      skillError = e instanceof Error ? e.message : String(e);
    }
  }

  function skillSourceLabel(skill: Skill): string {
    switch (skill.source.kind) {
      case "starter": return "Starter";
      case "localImport": return "Claude Code";
      case "github": return "GitHub";
      case "manual": return "Manual";
    }
  }

  // ---- Aqua page state ----
  let aquaKeyInput = $state("");
  let memoryInput = $state("");
  let aquaStatus = $state<string | null>(null);

  async function saveAquaKey() {
    app.settings.aquaApiKey = aquaKeyInput.trim();
    aquaKeyInput = "";
    app.saveSoon();
    aquaStatus = "Checking…";
    await app.refreshModels();
    aquaStatus = app.aquaModels.length
      ? `Connected — ${app.aquaModels.length} models available.`
      : "Key saved, but no models came back — check the key.";
  }

  function removeAquaKey() {
    app.settings.aquaApiKey = "";
    app.aquaModels = [];
    app.reconcileSelectedModel();
    app.saveSoon();
    aquaStatus = null;
  }

  // ---- Custom provider editor state ----
  let editingProvider = $state<CustomProvider | null>(null);
  let editorName = $state("");
  let editorBase = $state("");
  let editorKey = $state("");
  let editorModels = $state("");

  function startNewProvider() {
    editingProvider = { id: uid(), displayName: "", baseURL: "", apiKey: "", modelIDs: [] };
    editorName = ""; editorBase = ""; editorKey = ""; editorModels = "";
  }

  function startEditProvider(config: CustomProvider) {
    editingProvider = config;
    editorName = config.displayName;
    editorBase = config.baseURL;
    editorKey = config.apiKey;
    editorModels = config.modelIDs.join("\n");
  }

  function saveProvider() {
    if (!editingProvider) return;
    const config: CustomProvider = {
      id: editingProvider.id,
      displayName: editorName.trim() || "Custom provider",
      baseURL: editorBase.trim().replace(/\/$/, ""),
      apiKey: editorKey.trim(),
      modelIDs: editorModels.split("\n").map((s) => s.trim()).filter(Boolean),
    };
    const index = app.settings.customProviders.findIndex((c) => c.id === config.id);
    if (index >= 0) app.settings.customProviders[index] = config;
    else app.settings.customProviders.push(config);
    editingProvider = null;
    app.reconcileSelectedModel();
    app.saveSoon();
    app.settingsPage = `custom:${config.id}`;
  }

  function deleteProvider(id: string) {
    app.settings.customProviders = app.settings.customProviders.filter((c) => c.id !== id);
    app.reconcileSelectedModel();
    app.saveSoon();
    app.settingsPage = "general";
  }

  const currentProvider = $derived.by(() => {
    if (!app.settingsPage.startsWith("custom:")) return null;
    const id = app.settingsPage.slice("custom:".length);
    return app.settings.customProviders.find((c) => c.id === id) ?? null;
  });

  const SHORTCUTS: Array<[string, string]> = [
    ["New chat", `${modKeyLabel} N`],
    ["Projects", `${modKeyLabel} P`],
    ["Search", `${modKeyLabel} K`],
    ["Send message", "Enter"],
    ["New line", "Shift Enter"],
    ["Close overlay", "Esc"],
  ];

  function setTheme(theme: ThemeChoice) {
    app.settings.theme = theme;
    app.applyAppearance();
    app.saveSoon();
  }

  function setFontSize(size: FontSizeChoice) {
    app.settings.fontSize = size;
    app.applyAppearance();
    app.saveSoon();
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
<div class="overlay" onclick={() => (app.settingsOpen = false)}>
  <div class="card" onclick={(e) => e.stopPropagation()}>
    <div class="side">
      <div class="side-title">Settings</div>
      <div class="side-scroll">
        {#each CATEGORIES as category}
          <button
            class="cat"
            class:sel={app.settingsPage === category.id}
            onclick={() => (app.settingsPage = category.id)}
          >
            <span class="cat-icon"><Icon name={category.icon} size={14} /></span>
            <span class="cat-title">{category.title}</span>
            {#if category.beta}<span class="beta">BETA</span>{/if}
          </button>
        {/each}

        <div class="providers-head">
          <span>MODEL PROVIDERS</span>
          <button class="mini" title="Add a custom provider" onclick={() => { startNewProvider(); app.settingsPage = "custom-editor"; }}>
            <Icon name="plus" size={12} stroke={2.4} />
          </button>
        </div>

        {#if app.settings.aquaApiKey}
          <button class="cat" class:sel={app.settingsPage === "aqua"} onclick={() => (app.settingsPage = "aqua")}>
            <span class="cat-icon aqua"><Icon name="drop" size={13} /></span>
            <span class="cat-title">Aqua API</span>
          </button>
        {:else}
          <button class="cat" class:sel={app.settingsPage === "aqua"} onclick={() => (app.settingsPage = "aqua")}>
            <span class="cat-icon aqua"><Icon name="plus" size={13} /></span>
            <span class="cat-title">Add Aqua API</span>
          </button>
        {/if}

        {#each app.settings.customProviders as config (config.id)}
          <button
            class="cat"
            class:sel={app.settingsPage === `custom:${config.id}`}
            onclick={() => (app.settingsPage = `custom:${config.id}`)}
          >
            <span class="cat-icon mono">{config.displayName.slice(0, 1).toUpperCase()}</span>
            <span class="cat-title">{config.displayName}</span>
          </button>
        {/each}

        <div class="providers-head"><span>LOCAL</span></div>
        <button class="cat" class:sel={app.settingsPage === "ollama"} onclick={() => (app.settingsPage = "ollama")}>
          <span class="cat-icon"><Icon name="laptop" size={14} /></span>
          <span class="cat-title">Ollama</span>
          {#if app.ollamaReachable}<span class="live-dot"></span>{/if}
        </button>
      </div>
    </div>

    <div class="content">
      <button class="close" onclick={() => (app.settingsOpen = false)}>
        <Icon name="xmark" size={12} stroke={2.2} />
      </button>

      {#if app.settingsPage === "general"}
        <div class="page">
          <h2>General</h2>
          <div class="scard about">
            <span class="app-mark"><Icon name="drop" size={26} /></span>
            <div class="about-text">
              <div class="about-name">Eaon</div>
              <div class="about-tag">Unified Free AI API Platform for Top Models</div>
              <div class="about-version">Version 2026.3.0 · Windows preview</div>
            </div>
            <a class="link" href="https://eaon.dev" target="_blank" rel="noreferrer">eaon.dev</a>
          </div>
          <div class="scard">
            <div class="srow">
              <div style="flex: 1; min-width: 0;">
                <div class="srow-title">Updates</div>
                <div class="srow-sub">
                  {#if app.updateCheckState.status === "idle"}
                    Check what the latest Eaon release is.
                  {:else if app.updateCheckState.status === "checking"}
                    Checking…
                  {:else if app.updateCheckState.status === "error"}
                    <span style="color: var(--destructive)">{app.updateCheckState.message}</span>
                  {:else}
                    Latest release: {app.updateCheckState.latestVersion}
                  {/if}
                </div>
                {#if app.updateCheckState.status === "done" && app.updateCheckState.notes}
                  <div class="release-notes">{app.updateCheckState.notes}</div>
                {/if}
              </div>
              {#if app.updateCheckState.status === "done" && app.updateCheckState.url}
                <a class="mini-btn" style="text-decoration: none;" href={app.updateCheckState.url} target="_blank" rel="noreferrer">Download</a>
              {/if}
              <button class="mini-btn" disabled={app.updateCheckState.status === "checking"} onclick={() => app.checkForUpdate()}>Check for Updates</button>
            </div>
          </div>
          <div class="scard">
            <div class="srow">
              <div style="flex: 1; min-width: 0;">
                <div class="srow-title">Network proxy</div>
                <div class="srow-sub">Route Eaon's outbound traffic through an HTTP(S) proxy — for corporate or firewalled networks. {#if app.proxyError}<span style="color: var(--destructive)">{app.proxyError}</span>{/if}</div>
              </div>
              <Switch bind:checked={app.settings.proxyEnabled} onchange={() => { app.saveSoon(); app.applyProxy(); }} />
            </div>
            {#if app.settings.proxyEnabled}
              <div class="srow">
                <input
                  style="flex: 1;"
                  class="port-input"
                  bind:value={app.settings.proxyUrl}
                  placeholder="http://127.0.0.1:8080"
                  onchange={() => { app.saveSoon(); app.applyProxy(); }}
                />
              </div>
            {/if}
          </div>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">App Data</div>
                <div class="srow-sub">Conversations and settings are stored locally on this PC.</div>
              </div>
            </div>
          </div>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Need help?</div>
                <div class="srow-sub link-text">support@eaon.dev</div>
              </div>
            </div>
          </div>
        </div>
      {:else if app.settingsPage === "instructions"}
        <div class="page">
          <h2>Custom Instructions</h2>
          <p class="blurb">Sent with every request as your own system instruction — how you want Eaon to respond, in your words.</p>
          <textarea
            class="instructions"
            bind:value={app.settings.customInstructions}
            oninput={() => app.saveSoon()}
            placeholder="e.g. Be concise. When you show code, prefer TypeScript."
          ></textarea>
        </div>
      {:else if app.settingsPage === "appearance"}
        <div class="page">
          <h2>Appearance</h2>
          <div class="sect-label">Theme</div>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Appearance</div>
                <div class="srow-sub">Choose how Eaon looks.</div>
              </div>
              <select value={app.settings.theme} onchange={(e) => setTheme(e.currentTarget.value as ThemeChoice)}>
                <option>Light</option><option>Dark</option><option>System</option>
              </select>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div>
                <div class="srow-title">Font Size</div>
                <div class="srow-sub">Adjust the app's font size.</div>
              </div>
              <select value={app.settings.fontSize} onchange={(e) => setFontSize(e.currentTarget.value as FontSizeChoice)}>
                <option>Small</option><option>Medium</option><option>Large</option>
              </select>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div>
                <div class="srow-title">Accent Color</div>
                <div class="srow-sub">Used for buttons, links, and selection states.</div>
              </div>
            </div>
            <div class="accents">
              {#each ACCENT_OPTIONS as option (option.id)}
                <button
                  class="accent-dot"
                  class:sel={app.settings.accentColorId === option.id}
                  style="background:{option.color}"
                  title={option.id}
                  aria-label={option.id}
                  onclick={() => { app.settings.accentColorId = option.id; app.applyAppearance(); app.saveSoon(); }}
                ></button>
              {/each}
            </div>
          </div>
          <div class="sect-label">Chat</div>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Colored user bubble</div>
                <div class="srow-sub">Tint your own messages with the accent color instead of a neutral gray.</div>
              </div>
              <Switch bind:checked={app.settings.coloredUserBubble} onchange={() => app.saveSoon()} />
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div>
                <div class="srow-title">Show token speed</div>
                <div class="srow-sub">Show tokens per second under finished replies.</div>
              </div>
              <Switch bind:checked={app.settings.showTokenSpeed} onchange={() => app.saveSoon()} />
            </div>
          </div>
        </div>
      {:else if app.settingsPage === "shortcuts"}
        <div class="page">
          <h2>Shortcuts</h2>
          <div class="scard">
            {#each SHORTCUTS as [label, keys], index}
              {#if index > 0}<div class="sdiv"></div>{/if}
              <div class="srow">
                <div class="srow-title">{label}</div>
                <span class="kbd">{keys}</span>
              </div>
            {/each}
          </div>
        </div>
      {:else if app.settingsPage === "privacy"}
        <div class="page">
          <h2>Privacy</h2>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Web search</div>
                <div class="srow-sub">Let models search the web when they need current information. (Arrives with plugins on Windows.)</div>
              </div>
              <Switch bind:checked={app.settings.webSearchEnabled} onchange={() => app.saveSoon()} />
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div>
                <div class="srow-title">Always allow tool calls</div>
                <div class="srow-sub">Run tool calls without asking each time once agent features arrive.</div>
              </div>
              <Switch bind:checked={app.settings.alwaysAllowTools} onchange={() => app.saveSoon()} />
            </div>
          </div>
          <p class="blurb">Chats and settings never leave this PC except as requests to the model provider you picked.</p>
        </div>
      {:else if app.settingsPage === "statistics"}
        <div class="page">
          <h2>Statistics</h2>
          <div class="stat-grid">
            <div class="scard stat">
              <div class="stat-num">{app.statistics.promptsSent}</div>
              <div class="stat-label">Prompts sent</div>
            </div>
            <div class="scard stat">
              <div class="stat-num">{Math.round(app.statistics.charsGenerated / 4).toLocaleString()}</div>
              <div class="stat-label">Tokens generated (approx.)</div>
            </div>
          </div>
          {#if Object.keys(app.statistics.perModel).length}
            <div class="sect-label">By model</div>
            <div class="scard">
              {#each Object.entries(app.statistics.perModel) as [key, stats], index}
                {#if index > 0}<div class="sdiv"></div>{/if}
                <div class="srow">
                  <div class="srow-title mono-text">{key}</div>
                  <span class="srow-sub">{stats.prompts} prompt{stats.prompts === 1 ? "" : "s"} · ~{Math.round(stats.chars / 4).toLocaleString()} tok</span>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {:else if app.settingsPage === "hardware"}
        <div class="page">
          <h2>Hardware</h2>
          <div class="scard">
            <div class="srow">
              <div class="srow-title">Platform</div>
              <span class="srow-sub">{navigator.platform}</span>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div class="srow-title">CPU threads</div>
              <span class="srow-sub">{navigator.hardwareConcurrency}</span>
            </div>
          </div>
          <p class="blurb">Local models run through Ollama, which manages its own CPU/GPU use.</p>
        </div>
      {:else if app.settingsPage === "aqua"}
        <div class="page">
          <h2>Aqua API</h2>
          <p class="blurb">Aqua Devs' hosted models — one key, many frontier models.</p>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">API Key</div>
                <div class="srow-sub">
                  {app.settings.aquaApiKey ? "A key is saved on this PC." : "Paste your Aqua API key to connect."}
                </div>
              </div>
            </div>
            <div class="key-row">
              <input type="password" bind:value={aquaKeyInput} placeholder="Paste your Aqua API key" />
              <button class="accent-btn" disabled={!aquaKeyInput.trim()} onclick={saveAquaKey}>Save</button>
              {#if app.settings.aquaApiKey}
                <button class="ghost-btn destructive" onclick={removeAquaKey}>Remove</button>
              {/if}
            </div>
            {#if aquaStatus}<div class="status">{aquaStatus}</div>{/if}
          </div>
          {#if app.settings.aquaApiKey}
            <div class="sect-label">Models</div>
            <div class="scard">
              {#each app.aquaModels as model, index (model.id)}
                {#if index > 0}<div class="sdiv"></div>{/if}
                <div class="srow">
                  <div class="srow-title mono-text">{model.id}</div>
                  <span class="srow-sub">{model.name ?? ""}</span>
                </div>
              {:else}
                <div class="srow"><span class="srow-sub">No models loaded yet — check the key.</span></div>
              {/each}
            </div>
          {/if}
        </div>
      {:else if app.settingsPage === "custom-editor" || (currentProvider && app.settingsPage.startsWith("custom:") && editingProvider?.id === currentProvider.id)}
        <div class="page">
          <h2>{app.settings.customProviders.some((c) => c.id === editingProvider?.id) ? "Edit Provider" : "Add Provider"}</h2>
          <p class="blurb">Any OpenAI-compatible endpoint — Groq, OpenRouter, Together, a gateway of your own.</p>
          <div class="scard form">
            <label>Name <input bind:value={editorName} placeholder="e.g. Groq" /></label>
            <label>Base URL <input bind:value={editorBase} placeholder="https://api.groq.com/openai/v1" /></label>
            <label>API Key <input type="password" bind:value={editorKey} placeholder="sk-…" /></label>
            <label>Model IDs (one per line)
              <textarea bind:value={editorModels} rows="4" placeholder="llama-3.3-70b-versatile"></textarea>
            </label>
            <div class="form-actions">
              <button class="ghost-btn" onclick={() => { editingProvider = null; app.settingsPage = "general"; }}>Cancel</button>
              <button class="accent-btn" disabled={!editorBase.trim()} onclick={saveProvider}>Save</button>
            </div>
          </div>
        </div>
      {:else if currentProvider}
        <div class="page">
          <h2>{currentProvider.displayName}</h2>
          <div class="scard">
            <div class="srow">
              <div class="srow-title">Base URL</div>
              <span class="srow-sub mono-text">{currentProvider.baseURL}</span>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div class="srow-title">API Key</div>
              <span class="srow-sub">{currentProvider.apiKey ? "Saved" : "None"}</span>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div class="srow-title">Models</div>
              <span class="srow-sub">{currentProvider.modelIDs.length}</span>
            </div>
          </div>
          <div class="form-actions">
            <button class="ghost-btn" onclick={() => startEditProvider(currentProvider)}>Edit</button>
            <button class="ghost-btn destructive" onclick={() => deleteProvider(currentProvider.id)}>Delete provider</button>
          </div>
        </div>
      {:else if app.settingsPage === "ollama"}
        <div class="page">
          <h2>Ollama</h2>
          <p class="blurb">Run open models fully on this PC — private, free, no key. Install from ollama.com, then pull models from the Models page.</p>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Status</div>
                <div class="srow-sub">
                  {app.ollamaReachable
                    ? `Running — ${app.ollamaModels.length} model${app.ollamaModels.length === 1 ? "" : "s"} ready`
                    : "Not reachable — is Ollama running?"}
                </div>
              </div>
              <button class="ghost-btn" onclick={() => app.refreshModels()}>Refresh</button>
            </div>
            <div class="sdiv"></div>
            <div class="srow">
              <div>
                <div class="srow-title">Server URL</div>
              </div>
              <input
                class="url-input"
                bind:value={app.settings.ollamaBaseUrl}
                onchange={() => { app.saveSoon(); app.refreshModels(); }}
              />
            </div>
          </div>
          {#if app.ollamaModels.length}
            <div class="sect-label">Installed models</div>
            <div class="scard">
              {#each app.ollamaModels as model, index (model.name)}
                {#if index > 0}<div class="sdiv"></div>{/if}
                <div class="srow">
                  <div>
                    <div class="srow-title mono-text">{model.name}</div>
                    <div class="srow-sub">{formatBytes(model.sizeBytes)}{model.paramSize ? ` · ${model.paramSize}` : ""}{model.quantization ? ` · ${model.quantization}` : ""}</div>
                  </div>
                  <button class="mini-trash" title="Delete from this PC" onclick={() => (app.dialog = { kind: "deleteModel", name: model.name })}>
                    <Icon name="trash" size={13} />
                  </button>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {:else if app.settingsPage === "memory"}
        <div class="page">
          <h2>Memory</h2>
          <p class="blurb">Eaon can quietly remember durable facts from your conversations — your name, what you're working on, preferences — and bring them into future chats so it feels like it knows you. Everything stays on this PC.</p>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Learn from conversations</div>
                <div class="srow-sub">After a chat, Eaon extracts anything worth remembering. Turn off to stop learning (kept memories still apply).</div>
              </div>
              <Switch bind:checked={app.settings.memoryEnabled} onchange={() => app.saveSoon()} />
            </div>
          </div>

          <div class="scard">
            <div class="srow">
              <div style="flex: 1; min-width: 0;">
                <div class="srow-title">Add a memory</div>
                <div class="srow-sub">Tell Eaon something to remember about you.</div>
              </div>
            </div>
            <div class="srow" style="gap: 8px;">
              <input
                style="flex: 1;"
                class="port-input"
                bind:value={memoryInput}
                placeholder="e.g. I prefer TypeScript and concise answers"
                onkeydown={(e) => { if (e.key === "Enter") { app.addManualMemory(memoryInput); memoryInput = ""; } }}
              />
              <button class="mini-btn" onclick={() => { app.addManualMemory(memoryInput); memoryInput = ""; }}>Add</button>
            </div>
          </div>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Remembered ({app.sortedMemories.length})</div>
                <div class="srow-sub">What Eaon currently knows about you.</div>
              </div>
              {#if app.sortedMemories.length}
                <button class="mini-btn" onclick={() => app.clearMemories()}>Clear all</button>
              {/if}
            </div>
            {#if !app.sortedMemories.length}
              <div class="srow"><div class="srow-sub">Nothing yet — Eaon will learn as you chat.</div></div>
            {:else}
              {#each app.sortedMemories as mem (mem.id)}
                <div class="srow mem-row">
                  <div class="mem-text">{mem.text}</div>
                  <button class="mem-del" title="Forget this" onclick={() => app.removeMemory(mem.id)}>
                    <Icon name="trash" size={14} />
                  </button>
                </div>
              {/each}
            {/if}
          </div>
        </div>
      {:else if app.settingsPage === "localServer"}
        <div class="page">
          <h2>Local API Server <span class="beta big">BETA</span></h2>
          <p class="blurb">Turns this PC into a local OpenAI-compatible server. Any tool that speaks the OpenAI chat API — a script, a coding CLI, another app — can point at the base URL below and use whichever models you've configured here (Aqua, a BYOK key, or a local Ollama model). It binds to loopback only and requires a key by default.</p>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Enable server</div>
                <div class="srow-sub">
                  {#if app.localServerError}
                    <span style="color: var(--destructive)">Couldn't start: {app.localServerError}</span>
                  {:else if app.localServerRunning}
                    Running at {app.localServerBaseUrl}
                  {:else}
                    Off — turn on to start accepting local requests.
                  {/if}
                </div>
              </div>
              <Switch bind:checked={app.settings.localServerEnabled} onchange={() => app.applyLocalServer()} />
            </div>
          </div>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Port</div>
                <div class="srow-sub">The loopback port to listen on. 1234 matches LM Studio's default.</div>
              </div>
              <input
                class="port-input"
                type="number"
                min="1"
                max="65535"
                value={app.settings.localServerPort}
                onchange={(e) => { app.settings.localServerPort = Number(e.currentTarget.value) || 1234; app.saveSoon(); if (app.settings.localServerEnabled) app.applyLocalServer(); }}
              />
            </div>
            <div class="srow">
              <div>
                <div class="srow-title">Require API key</div>
                <div class="srow-sub">Callers must send <code>Authorization: Bearer &lt;key&gt;</code>. Keep this on — any other process on this PC could otherwise use your providers.</div>
              </div>
              <Switch bind:checked={app.settings.localServerRequireApiKey} onchange={() => { app.saveSoon(); if (app.settings.localServerEnabled) app.applyLocalServer(); }} />
            </div>
          </div>

          <div class="scard">
            <div class="srow">
              <div style="flex: 1; min-width: 0;">
                <div class="srow-title">API key</div>
                <div class="srow-sub mono-key">{app.settings.localServerApiKey}</div>
              </div>
              <button class="mini-btn" onclick={() => navigator.clipboard.writeText(app.settings.localServerApiKey)}>Copy</button>
              <button class="mini-btn" onclick={() => app.regenerateLocalServerKey()}>Regenerate</button>
            </div>
            <div class="srow">
              <div style="flex: 1; min-width: 0;">
                <div class="srow-title">Base URL</div>
                <div class="srow-sub mono-key">{app.localServerBaseUrl}</div>
              </div>
              <button class="mini-btn" onclick={() => navigator.clipboard.writeText(app.localServerBaseUrl)}>Copy</button>
            </div>
          </div>
        </div>
      {:else if app.settingsPage === "plugins"}
        <div class="page">
          <h2>Plugins</h2>
          <p class="blurb">Connect outside services through MCP (Model Context Protocol) so Eaon can act on them for you — read your issues, create records, query your database. Remote servers take a pasted API token; local servers run as a command on this PC.</p>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Add a service</div>
                <div class="srow-sub">One-click presets (paste your token after picking), or a fully custom server below.</div>
              </div>
              <button class="mini-btn" onclick={() => startMcpServer()}>Custom</button>
            </div>
            <div class="srow" style="flex-wrap: wrap; gap: 6px;">
              {#each MCP_PRESETS as preset (preset.name)}
                <button class="mini-btn" onclick={() => startMcpServer(preset)}>{preset.name}</button>
              {/each}
            </div>
          </div>

          {#if editingMcp}
            <div class="scard">
              <div class="srow">
                <div>
                  <div class="srow-title">{app.settings.mcpServers.some((s) => s.id === editingMcp?.id) ? "Edit server" : "New server"}</div>
                  <div class="srow-sub">
                    {mcpTransport === "http"
                      ? "A remote MCP endpoint — the service's MCP URL plus an API token from that service's settings."
                      : "A local MCP server launched as a process — e.g. npx @modelcontextprotocol/server-filesystem"}
                  </div>
                </div>
                <select value={mcpTransport} onchange={(e) => (mcpTransport = e.currentTarget.value as "http" | "stdio")}>
                  <option value="http">Remote (HTTP)</option>
                  <option value="stdio">Local (command)</option>
                </select>
              </div>
              <div class="srow"><input style="flex: 1;" class="port-input" bind:value={mcpName} placeholder="Display name — e.g. GitHub" /></div>
              {#if mcpTransport === "http"}
                <div class="srow"><input style="flex: 1;" class="port-input" bind:value={mcpUrl} placeholder="https://mcp.example.com/mcp" /></div>
                <div class="srow" style="gap: 8px;">
                  <input style="width: 130px;" class="port-input" bind:value={mcpScheme} placeholder="Bearer" title="Authorization scheme — Bearer for nearly all services" />
                  <input style="flex: 1;" class="port-input" type="password" bind:value={mcpToken} placeholder="API token" />
                </div>
              {:else}
                <div class="srow" style="gap: 8px;">
                  <input style="width: 130px;" class="port-input" bind:value={mcpCommand} placeholder="npx" />
                  <input style="flex: 1;" class="port-input" bind:value={mcpArgs} placeholder="-y @modelcontextprotocol/server-filesystem C:\Users\you" />
                </div>
              {/if}
              <div class="srow" style="justify-content: flex-end; gap: 8px;">
                <button class="mini-btn" onclick={() => (editingMcp = null)}>Cancel</button>
                <button
                  class="mini-btn"
                  disabled={mcpTransport === "http" ? !mcpUrl.trim() : !mcpCommand.trim()}
                  onclick={saveMcpServer}
                >Save &amp; Connect</button>
              </div>
            </div>
          {/if}

          <div class="scard">
            {#if !app.settings.mcpServers.length}
              <div class="srow"><div class="srow-sub">No services connected yet.</div></div>
            {:else}
              {#each app.settings.mcpServers as server, index (server.id)}
                {@const conn = app.mcpConnections[server.id]}
                {#if index > 0}<div class="sdiv"></div>{/if}
                <div class="srow">
                  <div style="flex: 1; min-width: 0;">
                    <div class="skill-name-line">
                      <span class="srow-title">{server.name}</span>
                      {#if conn?.status === "connected"}
                        <span class="live-dot"></span>
                        <span class="skill-tag">{conn.tools.length} tools</span>
                      {:else if conn?.status === "connecting"}
                        <span class="skill-tag">connecting…</span>
                      {/if}
                    </div>
                    <div class="srow-sub mono-key">{server.transport === "http" ? server.url : `${server.command} ${server.args}`.trim()}</div>
                    {#if conn?.status === "error"}
                      <div class="srow-sub" style="color: var(--destructive)">{conn.error}</div>
                    {/if}
                  </div>
                  <button class="mini-btn" onclick={() => startEditMcpServer(server)}>Edit</button>
                  <button class="mini-btn" onclick={() => app.connectMcpServer(server)}>Reconnect</button>
                  <button class="mem-del" title="Remove" onclick={() => app.removeMcpServer(server.id)}>
                    <Icon name="trash" size={14} />
                  </button>
                  <Switch checked={server.enabled} onchange={() => toggleMcpServer(server)} />
                </div>
              {/each}
            {/if}
          </div>
        </div>
      {:else if app.settingsPage === "computer"}
        <div class="page">
          <h2>Eaon Claw <span class="beta big">BETA</span></h2>
          <p class="blurb">Lets Agent mode act on this PC beyond coding — organize files and drive apps and websites when you ask. These wider tools fold into Agent mode; there's no separate mode to switch to.</p>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Device control</div>
                <div class="srow-sub">When on, Agent mode also gets the tools below. Off means they don't exist as far as the model knows — and are refused even if it tries.</div>
              </div>
              <Switch bind:checked={app.settings.deviceControlEnabled} onchange={() => app.saveSoon()} />
            </div>
            <div class="srow">
              <div>
                <div class="srow-title">Ask before each action</div>
                <div class="srow-sub">Sandboxed mode — every file-changing or device action needs your OK first. Turn "Always allow" off to get asked.</div>
              </div>
              <Switch
                checked={!app.settings.alwaysAllowTools}
                onchange={(on) => { app.settings.alwaysAllowTools = !on; app.saveSoon(); }}
              />
            </div>
          </div>

          <div class="scard">
            {#each CLAW_CAPABILITIES as [name, sub], index (name)}
              {#if index > 0}<div class="sdiv"></div>{/if}
              <div class="srow" style="opacity: {app.settings.deviceControlEnabled ? 1 : 0.55};">
                <div>
                  <div class="srow-title">{name}</div>
                  <div class="srow-sub">{sub}</div>
                </div>
              </div>
            {/each}
          </div>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Not on Windows/Linux</div>
                <div class="srow-sub">The Mac version can also drive scriptable apps via AppleScript — that has no Windows/Linux equivalent and is deliberately absent rather than half-working.</div>
              </div>
            </div>
          </div>
        </div>
      {:else if app.settingsPage === "modelParams"}
        {@const params = app.settings.modelParams}
        <div class="page">
          <h2>Model Parameters</h2>
          <p class="blurb">Global inference controls, applied to every model. Each is off by default — off means the field isn't sent at all, so the model keeps its own tuned default. Some models (reasoning models especially) reject these; Eaon retries without them automatically.</p>

          <div class="scard">
            {#each [
              { key: "temperature", label: "Temperature", sub: "Randomness — lower is more focused, higher more creative.", min: 0, max: 2, step: 0.05 },
              { key: "topP", label: "Top-P", sub: "Nucleus sampling — the probability mass the model may pick from.", min: 0, max: 1, step: 0.01 },
              { key: "maxTokens", label: "Max Tokens", sub: "Hard cap on each reply's length.", min: 256, max: 16384, step: 256 },
              { key: "frequencyPenalty", label: "Frequency Penalty", sub: "Discourages repeating the same words.", min: -2, max: 2, step: 0.1 },
              { key: "presencePenalty", label: "Presence Penalty", sub: "Encourages bringing up new topics.", min: -2, max: 2, step: 0.1 },
            ] as row, index (row.key)}
              {@const enabledKey = `${row.key}Enabled` as keyof typeof params}
              {@const valueKey = row.key as keyof typeof params}
              {#if index > 0}<div class="sdiv"></div>{/if}
              <div class="srow">
                <div style="flex: 1; min-width: 0;">
                  <div class="srow-title">{row.label}{#if params[enabledKey]}<span class="param-value">{params[valueKey]}</span>{/if}</div>
                  <div class="srow-sub">{row.sub}</div>
                  {#if params[enabledKey]}
                    <input
                      class="param-slider"
                      type="range"
                      min={row.min}
                      max={row.max}
                      step={row.step}
                      value={Number(params[valueKey])}
                      oninput={(e) => { (params[valueKey] as number) = Number(e.currentTarget.value); app.saveSoon(); }}
                    />
                  {/if}
                </div>
                <Switch
                  checked={Boolean(params[enabledKey])}
                  onchange={(on) => { (params[enabledKey] as boolean) = on; app.saveSoon(); }}
                />
              </div>
            {/each}
          </div>
        </div>
      {:else if app.settingsPage === "imageProviders"}
        <div class="page">
          <h2>Image Providers</h2>
          <p class="blurb">Generate images in any chat — ask for a picture and the model creates it with whichever backend you set up here: a cloud image API, a Stable Diffusion server on this PC, a local Ollama diffusion model, or Aqua's hosted image models.</p>

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Let models generate images</div>
                <div class="srow-sub">When on (and a backend below is available), chat models can create images on request.</div>
              </div>
              <Switch bind:checked={app.settings.imageToolEnabled} onchange={() => app.saveSoon()} />
            </div>
            <div class="srow">
              <div>
                <div class="srow-title">Active backend</div>
                <div class="srow-sub">
                  {#if app.settings.imageProviders.length}
                    {app.settings.imageProviders[0].displayName} (first connection below)
                  {:else if app.ollamaModels.some((m) => m.capabilities?.includes("image"))}
                    Local Ollama — {app.ollamaModels.find((m) => m.capabilities?.includes("image"))?.name}
                  {:else if app.aquaImageModels.length && app.settings.aquaApiKey}
                    Aqua — {app.aquaImageModels[0]}
                  {:else}
                    None yet — add a connection below, pull an Ollama image model, or add an Aqua key.
                  {/if}
                </div>
              </div>
            </div>
          </div>

          {#if editingImageProvider}
            <div class="scard">
              <div class="srow">
                <div>
                  <div class="srow-title">{app.settings.imageProviders.some((c) => c.id === editingImageProvider?.id) ? "Edit connection" : "Add a connection"}</div>
                  <div class="srow-sub">
                    {imgFormat === "openai"
                      ? "A cloud /images/generations API — OpenAI's gpt-image/DALL-E, or any provider speaking the same shape."
                      : "A Stable Diffusion server on this PC — Automatic1111 WebUI, or ComfyUI in compatibility mode, usually at http://127.0.0.1:7860."}
                  </div>
                </div>
                <select value={imgFormat} onchange={(e) => (imgFormat = e.currentTarget.value as ImageWireFormat)}>
                  <option value="openai">Cloud API (OpenAI-style)</option>
                  <option value="automatic1111">Local Server</option>
                </select>
              </div>
              <div class="srow"><input style="flex: 1;" class="port-input" bind:value={imgName} placeholder="Display name — e.g. OpenAI Images" /></div>
              <div class="srow"><input style="flex: 1;" class="port-input" bind:value={imgBase} placeholder={imgFormat === "openai" ? "https://api.openai.com/v1" : "http://127.0.0.1:7860"} /></div>
              {#if imgFormat === "openai"}
                <div class="srow"><input style="flex: 1;" class="port-input" type="password" bind:value={imgKey} placeholder="API key" /></div>
                <div class="srow"><textarea class="skill-editor" style="min-height: 60px;" bind:value={imgModels} placeholder={"Model ids, one per line — e.g.\ngpt-image-1"}></textarea></div>
              {/if}
              <div class="srow" style="justify-content: flex-end; gap: 8px;">
                <button class="mini-btn" onclick={() => (editingImageProvider = null)}>Cancel</button>
                <button class="mini-btn" disabled={!imgBase.trim() || (imgFormat === "openai" && !imgModels.trim())} onclick={saveImageProvider}>Save</button>
              </div>
            </div>
          {/if}

          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Connections ({app.settings.imageProviders.length})</div>
                <div class="srow-sub">The first connection is used for generation.</div>
              </div>
              <button class="mini-btn" onclick={() => startImageProvider(null)}>Add</button>
            </div>
            {#if !app.settings.imageProviders.length}
              <div class="srow"><div class="srow-sub">No image connections yet.</div></div>
            {:else}
              {#each app.settings.imageProviders as config (config.id)}
                <div class="srow">
                  <div style="flex: 1; min-width: 0;">
                    <div class="srow-title">{config.displayName}</div>
                    <div class="srow-sub mono-key">{config.format === "openai" ? (config.modelIDs[0] ?? "") + " · " : ""}{config.baseURL}</div>
                  </div>
                  <button class="mini-btn" onclick={() => startImageProvider(config)}>Edit</button>
                  <button class="mem-del" title="Remove" onclick={() => deleteImageProvider(config.id)}>
                    <Icon name="trash" size={14} />
                  </button>
                </div>
              {/each}
            {/if}
          </div>
        </div>
      {:else if app.settingsPage === "skills"}
        <div class="page">
          <h2>Skills <span class="beta big">BETA</span></h2>
          <p class="blurb">Reusable instructions a model follows on request — type /name in the message box to invoke one.</p>

          <div class="skill-add-row">
            <button class="mini-btn" class:active={skillAddMode === "github"} onclick={() => openSkillAdd("github")}>From GitHub</button>
            <button class="mini-btn" class:active={skillAddMode === "local"} onclick={() => openSkillAdd("local")}>From Claude Code</button>
            <button class="mini-btn" class:active={skillAddMode === "manual"} onclick={() => openSkillAdd("manual")}>Write One</button>
          </div>

          {#if skillAddMode === "github"}
            <div class="scard">
              <div class="srow">
                <div>
                  <div class="srow-title">Add from GitHub</div>
                  <div class="srow-sub">Paste a link to a SKILL.md file, its folder, or a repo (tries SKILL.md at the root).</div>
                </div>
              </div>
              <div class="srow" style="gap: 8px;">
                <input
                  style="flex: 1;"
                  class="port-input"
                  bind:value={skillGithubUrl}
                  placeholder="https://github.com/org/repo/blob/main/some-skill/SKILL.md"
                  onkeydown={(e) => { if (e.key === "Enter") installSkillFromGitHub(); }}
                />
                <button class="mini-btn" disabled={skillInstalling || !skillGithubUrl.trim()} onclick={installSkillFromGitHub}>
                  {skillInstalling ? "Installing…" : "Install"}
                </button>
              </div>
              {#if skillError}<div class="srow"><div class="srow-sub" style="color: var(--destructive)">{skillError}</div></div>{/if}
            </div>
          {:else if skillAddMode === "manual"}
            <div class="scard">
              <div class="srow">
                <div>
                  <div class="srow-title">Write a Skill</div>
                  <div class="srow-sub">A name to invoke it with, one line on when to use it, and the instructions themselves.</div>
                </div>
              </div>
              <div class="srow"><input style="flex: 1;" class="port-input" bind:value={skillName} placeholder="Name — e.g. terse-summaries" /></div>
              <div class="srow"><input style="flex: 1;" class="port-input" bind:value={skillSummary} placeholder="Description — when should the model reach for this?" /></div>
              <div class="srow"><textarea class="skill-editor" bind:value={skillInstructions} placeholder="Instructions the model follows when you invoke /name…"></textarea></div>
              {#if skillError}<div class="srow"><div class="srow-sub" style="color: var(--destructive)">{skillError}</div></div>{/if}
              <div class="srow" style="justify-content: flex-end; gap: 8px;">
                <button class="mini-btn" onclick={() => (skillAddMode = null)}>Cancel</button>
                <button class="mini-btn" disabled={!skillName.trim() || !skillSummary.trim() || !skillInstructions.trim()} onclick={saveManualSkill}>Save</button>
              </div>
            </div>
          {:else if skillAddMode === "local"}
            <div class="scard">
              <div class="srow">
                <div>
                  <div class="srow-title">Import from Claude Code</div>
                  <div class="srow-sub">Skills found in ~/.claude/skills/ on this PC that aren't already in your library.</div>
                </div>
              </div>
              {#if localSkillCandidates === null}
                <div class="srow"><div class="srow-sub">Scanning…</div></div>
              {:else if !localSkillCandidates.length}
                <div class="srow"><div class="srow-sub">Nothing new to import — either none were found, or everything there is already in your library.</div></div>
              {:else}
                {#each localSkillCandidates as candidate (candidate.path)}
                  <div class="srow">
                    <div style="flex: 1; min-width: 0;">
                      <div class="srow-title mono-key">/{candidate.parsed.name}</div>
                      <div class="srow-sub">{candidate.parsed.summary}</div>
                    </div>
                    {#if importedSkillPaths.has(candidate.path)}
                      <span class="srow-sub">Imported</span>
                    {:else}
                      <button class="mini-btn" onclick={() => { app.importLocalSkill(candidate); importedSkillPaths = new Set([...importedSkillPaths, candidate.path]); }}>Import</button>
                    {/if}
                  </div>
                {/each}
              {/if}
            </div>
          {/if}

          <div class="scard">
            {#if !app.sortedSkills.length}
              <div class="srow"><div class="srow-sub">No skills installed yet.</div></div>
            {:else}
              {#each app.sortedSkills as skill, index (skill.id)}
                {#if index > 0}<div class="sdiv"></div>{/if}
                <div class="srow skill-row" class:off={!skill.isEnabled}>
                  <div style="flex: 1; min-width: 0;">
                    <div class="skill-name-line">
                      <span class="srow-title mono-key">/{skill.name}</span>
                      <span class="skill-tag">{skillSourceLabel(skill)}</span>
                    </div>
                    <div class="srow-sub">{skill.summary}</div>
                  </div>
                  <button class="mem-del" title="Remove" onclick={() => app.removeSkill(skill.id)}>
                    <Icon name="trash" size={14} />
                  </button>
                  <Switch checked={skill.isEnabled} onchange={() => app.toggleSkill(skill.id)} />
                </div>
              {/each}
            {/if}
          </div>
        </div>
      {:else if COMING_SOON[app.settingsPage]}
        {@const meta = COMING_SOON[app.settingsPage]}
        <div class="page">
          <h2>{meta.title} {#if meta.beta}<span class="beta big">BETA</span>{/if}</h2>
          <p class="blurb">{meta.blurb}</p>
          <div class="scard">
            <div class="srow">
              <div>
                <div class="srow-title">Coming to Windows</div>
                <div class="srow-sub">This feature is live in Eaon for macOS and is being brought to the Windows version.</div>
              </div>
            </div>
          </div>
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: var(--bg-overlay);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 90;
  }
  .card {
    width: min(980px, calc(100vw - 24px));
    height: min(700px, calc(100vh - 24px));
    display: flex;
    background: var(--bg-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 16px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.3);
    overflow: hidden;
    animation: pop 0.16s ease-out;
  }
  @keyframes pop {
    from { transform: scale(0.96); opacity: 0; }
    to { transform: scale(1); opacity: 1; }
  }
  .side {
    width: 230px;
    flex-shrink: 0;
    background: var(--bg-sidebar);
    border-right: 1px solid var(--border-subtle);
    display: flex;
    flex-direction: column;
  }
  .side-title {
    font-family: var(--font-mono);
    font-size: 20px;
    font-weight: 700;
    padding: 20px 16px 12px;
  }
  .side-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 0 8px 12px;
  }
  .cat {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    border: none;
    background: transparent;
    border-radius: 8px;
    padding: 6px 8px;
    cursor: pointer;
    color: var(--text-primary);
    text-align: left;
  }
  .cat:hover {
    background: var(--bg-hover);
  }
  .cat.sel {
    background: var(--bg-selected);
  }
  .cat-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: 6px;
    background: var(--bg-subtle);
    color: var(--text-secondary);
    flex-shrink: 0;
  }
  .cat-icon.aqua {
    color: var(--accent);
  }
  .cat-icon.mono {
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
  }
  .cat-title {
    font-family: var(--font-sans);
    font-size: 13px;
    flex: 1;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .beta {
    font-family: var(--font-mono);
    font-size: 8.5px;
    font-weight: 700;
    color: #e8a838;
    background: color-mix(in srgb, #e8a838 14%, transparent);
    border-radius: 4px;
    padding: 2px 4px;
  }
  .beta.big {
    font-size: 10px;
    vertical-align: middle;
  }
  .port-input {
    width: 96px;
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 6px 10px;
    font-family: var(--font-mono);
    font-size: 13px;
    outline: none;
  }
  .port-input:focus { border-color: var(--border-medium); }
  .mini-btn {
    flex-shrink: 0;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    background: var(--bg-input-secondary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 6px 12px;
    cursor: pointer;
  }
  .mini-btn:hover { border-color: var(--border-medium); }
  .mono-key {
    font-family: var(--font-mono);
    font-size: 11.5px;
    word-break: break-all;
    color: var(--text-tertiary);
  }
  .mem-row { gap: 10px; }
  .mem-text {
    flex: 1;
    min-width: 0;
    font-family: var(--font-sans);
    font-size: 13px;
    color: var(--text-primary);
    line-height: 1.5;
  }
  .mem-del {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 7px;
    border: none;
    background: transparent;
    color: var(--text-tertiary);
    cursor: pointer;
  }
  .mem-del:hover { background: var(--bg-input-secondary); color: var(--destructive); }
  .skill-add-row {
    display: flex;
    gap: 8px;
    margin-bottom: 14px;
  }
  .mini-btn.active { border-color: var(--border-medium); background: var(--bg-chip); }
  .mini-btn:disabled { opacity: 0.5; cursor: default; }
  .skill-row.off .srow-title, .skill-row.off .srow-sub { color: var(--text-tertiary); }
  .skill-name-line {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 2px;
  }
  .skill-name-line .srow-title { font-family: var(--font-mono); font-size: 13px; }
  .skill-tag {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    color: var(--text-tertiary);
    background: var(--bg-chip-secondary);
    border-radius: 999px;
    padding: 2px 7px;
  }
  .skill-editor {
    flex: 1;
    min-height: 140px;
    resize: vertical;
    font-family: var(--font-mono);
    font-size: 12.5px;
    line-height: 1.55;
    color: var(--text-primary);
    background: var(--bg-input);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 10px 12px;
    outline: none;
  }
  .skill-editor:focus { border-color: var(--border-medium); }
  .param-value {
    margin-left: 8px;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-secondary);
  }
  .param-slider {
    display: block;
    width: 100%;
    max-width: 340px;
    margin-top: 8px;
    accent-color: var(--accent-user);
  }
  .release-notes {
    margin-top: 8px;
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 1.5;
    white-space: pre-wrap;
    max-height: 140px;
    overflow-y: auto;
  }
  .live-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #34c759;
  }
  .providers-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.8px;
    color: var(--text-tertiary);
    padding: 20px 8px 4px;
  }
  .mini {
    border: none;
    background: transparent;
    color: var(--text-tertiary);
    cursor: pointer;
    display: inline-flex;
    padding: 2px;
  }
  .content {
    flex: 1;
    min-width: 0;
    position: relative;
    background: var(--bg-primary);
    overflow-y: auto;
  }
  .close {
    position: absolute;
    top: 14px;
    right: 14px;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    border: none;
    background: var(--bg-subtle);
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    z-index: 5;
  }
  .page {
    padding: 28px 32px 32px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    max-width: 720px;
  }
  h2 {
    font-family: var(--font-mono);
    font-size: 20px;
    font-weight: 700;
    margin: 0 0 4px;
  }
  .blurb {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin: -8px 0 0;
    line-height: 1.55;
  }
  .sect-label {
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-tertiary);
    margin-bottom: -8px;
  }
  .scard {
    background: var(--bg-elevated);
    border: 1px solid var(--border-medium);
    border-radius: 10px;
    box-shadow: 0 2px 6px var(--shadow);
  }
  .srow {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 14px 16px;
  }
  .srow-title {
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .srow-sub {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
    line-height: 1.5;
  }
  .mono-text {
    font-family: var(--font-mono);
  }
  .link-text {
    color: var(--diff-added);
    font-family: var(--font-mono);
  }
  .sdiv {
    height: 1px;
    background: var(--border-subtle);
    margin: 0 16px;
  }
  .about {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 16px;
  }
  .app-mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 44px;
    height: 44px;
    border-radius: 11px;
    background: var(--accent);
    color: #fff;
  }
  .about-text {
    flex: 1;
  }
  .about-name {
    font-family: var(--font-mono);
    font-size: 18px;
    font-weight: 700;
  }
  .about-tag {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
  }
  .about-version {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
    margin-top: 2px;
  }
  .link {
    color: var(--link);
    font-family: var(--font-mono);
    font-size: 13px;
    text-decoration: none;
  }
  select {
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 6px 10px;
    font-family: var(--font-sans);
    font-size: 12px;
    width: 110px;
  }
  .accents {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    padding: 0 20px 18px;
  }
  .accent-dot {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    border: 2px solid transparent;
    cursor: pointer;
    box-shadow: inset 0 0 0 1px var(--border-medium);
  }
  .accent-dot.sel {
    border-color: var(--text-primary);
  }
  .kbd {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-secondary);
    background: var(--bg-subtle);
    border: 1px solid var(--border-subtle);
    border-radius: 6px;
    padding: 3px 8px;
  }
  .instructions {
    width: 100%;
    min-height: 220px;
    resize: vertical;
    background: var(--bg-elevated);
    color: var(--text-primary);
    border: 1px solid var(--border-medium);
    border-radius: 10px;
    padding: 14px;
    font-family: var(--font-sans);
    font-size: 13px;
    line-height: 1.6;
    outline: none;
  }
  .key-row {
    display: flex;
    gap: 8px;
    padding: 0 16px 14px;
  }
  .key-row input,
  .url-input {
    flex: 1;
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 8px 12px;
    font-family: var(--font-mono);
    font-size: 12px;
    outline: none;
  }
  .url-input {
    flex: 0 1 260px;
  }
  .status {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-secondary);
    padding: 0 16px 14px;
  }
  .accent-btn {
    border: none;
    border-radius: 999px;
    background: var(--text-primary);
    color: var(--bg-primary);
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    padding: 8px 16px;
    cursor: pointer;
  }
  .accent-btn:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .ghost-btn {
    border: 1px solid var(--border-medium);
    border-radius: 999px;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 12px;
    padding: 8px 16px;
    cursor: pointer;
  }
  .ghost-btn:hover {
    background: var(--bg-hover);
  }
  .ghost-btn.destructive {
    color: var(--destructive);
    border-color: color-mix(in srgb, var(--destructive) 40%, transparent);
  }
  .mini-trash {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    display: inline-flex;
    padding: 6px;
    border-radius: 6px;
  }
  .mini-trash:hover {
    background: var(--bg-hover);
    color: var(--destructive);
  }
  .form {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .form label {
    display: flex;
    flex-direction: column;
    gap: 6px;
    font-family: var(--font-sans);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-secondary);
  }
  .form input,
  .form textarea {
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 8px 12px;
    font-family: var(--font-mono);
    font-size: 12px;
    outline: none;
    resize: vertical;
  }
  .form-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }
  .stat-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }
  .stat {
    padding: 18px 16px;
  }
  .stat-num {
    font-family: var(--font-mono);
    font-size: 28px;
    font-weight: 700;
  }
  .stat-label {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 4px;
  }
</style>
