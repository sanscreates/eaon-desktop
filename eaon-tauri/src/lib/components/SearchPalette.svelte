<script lang="ts">
  // Port of SearchPaletteView.swift — the ⌘K/Ctrl+K overlay: 560px card,
  // one flat keyboard-navigable list (New chat, Chats with content search,
  // Settings pages, model switching, theme switching).
  import { app } from "$lib/state.svelte";
  import type { ThemeChoice } from "$lib/types";
  import Icon from "./Icon.svelte";

  let query = $state("");
  let selectedIndex = $state(0);
  let field = $state<HTMLInputElement | null>(null);

  $effect(() => {
    setTimeout(() => field?.focus(), 30);
  });

  const q = $derived(query.trim().toLowerCase());

  interface Item {
    id: string;
    icon: string;
    title: string;
    subtitle?: string;
    section: string | null;
    run: () => void;
  }

  const SETTINGS_PAGES: Array<[string, string, string]> = [
    ["General", "gear", "general"],
    ["Custom Instructions", "text-quote", "instructions"],
    ["Appearance", "paint", "appearance"],
    ["Shortcuts", "keyboard", "shortcuts"],
    ["Privacy", "lock", "privacy"],
    ["Statistics", "chart", "statistics"],
  ];

  const items = $derived.by<Item[]>(() => {
    const result: Item[] = [
      {
        id: "new-chat", icon: "new-chat", title: "New chat", section: null,
        run: () => app.newChat(),
      },
    ];
    for (const conversation of app.sortedConversations) {
      if (q && !conversation.title.toLowerCase().includes(q) &&
          !conversation.messages.some((m) => m.content.toLowerCase().includes(q))) continue;
      result.push({
        id: `chat:${conversation.id}`, icon: "message", title: conversation.title,
        subtitle: conversation.messages.find((m) => m.role === "assistant" && m.content)?.content.slice(0, 90),
        section: "Chats",
        run: () => app.selectConversation(conversation.id),
      });
    }
    for (const [title, icon, page] of SETTINGS_PAGES) {
      if (q && !title.toLowerCase().includes(q)) continue;
      result.push({
        id: `settings:${page}`, icon, title, section: "Settings",
        run: () => { app.settingsPage = page; app.settingsOpen = true; },
      });
    }
    if (q) {
      let modelCount = 0;
      for (const model of app.allModels) {
        if (modelCount >= 6) break;
        if (!model.display.toLowerCase().includes(q) && !model.requestId.toLowerCase().includes(q)) continue;
        modelCount++;
        result.push({
          id: `model:${model.key}`, icon: "cube", title: model.display,
          subtitle: model.provider.kind === "ollama" ? "Local" : undefined,
          section: "Switch model",
          run: () => app.selectModel(model.key),
        });
      }
      if ("theme".includes(q) || "appearance".includes(q) || "dark".includes(q) || "light".includes(q)) {
        for (const theme of ["Light", "Dark", "System"] as ThemeChoice[]) {
          result.push({
            id: `theme:${theme}`,
            icon: app.settings.theme === theme ? "check-circle-fill" : "circle",
            title: `${theme} theme`, section: "Theme",
            run: () => { app.settings.theme = theme; app.applyAppearance(); app.saveSoon(); },
          });
        }
      }
    }
    return result;
  });

  function activate(item: Item) {
    app.searchOpen = false;
    item.run();
  }

  function onKey(e: KeyboardEvent) {
    const count = items.length;
    if (e.key === "ArrowDown") { e.preventDefault(); selectedIndex = (selectedIndex + 1) % count; }
    else if (e.key === "ArrowUp") { e.preventDefault(); selectedIndex = (selectedIndex - 1 + count) % count; }
    else if (e.key === "Enter") { e.preventDefault(); const item = items[selectedIndex]; if (item) activate(item); }
    else if (e.key === "Escape") { app.searchOpen = false; }
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
<div class="overlay" onclick={() => (app.searchOpen = false)}>
  <div class="card" onclick={(e) => e.stopPropagation()}>
    <div class="field">
      <Icon name="search" size={17} />
      <input
        bind:this={field}
        bind:value={query}
        placeholder="Search chats, settings, models…"
        onkeydown={onKey}
        oninput={() => (selectedIndex = 0)}
      />
    </div>
    <div class="divider"></div>
    <div class="results">
      {#each items as item, index (item.id)}
        {#if item.section && (index === 0 || items[index - 1].section !== item.section)}
          <div class="sect">{item.section}</div>
        {/if}
        <button class="row" class:sel={index === selectedIndex} onclick={() => activate(item)}>
          <span class="row-icon"><Icon name={item.icon} size={15} /></span>
          <span class="row-text">
            <span class="row-title">{item.title}</span>
            {#if item.subtitle}<span class="row-sub">{item.subtitle}</span>{/if}
          </span>
        </button>
      {/each}
      {#if items.length <= 1 && q}
        <div class="none">No matches</div>
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
    align-items: flex-start;
    justify-content: center;
    padding-top: 14vh;
    z-index: 100;
  }
  .card {
    width: 560px;
    max-width: calc(100vw - 48px);
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 16px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.28);
    overflow: hidden;
    animation: pop 0.16s ease-out;
  }
  @keyframes pop {
    from { transform: scale(0.96); opacity: 0; }
    to { transform: scale(1); opacity: 1; }
  }
  .field {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 15px 18px;
    color: var(--text-secondary);
  }
  .field input {
    flex: 1;
    border: none;
    outline: none;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 17px;
  }
  .divider {
    height: 1px;
    background: var(--border-subtle);
  }
  .results {
    max-height: 380px;
    overflow-y: auto;
    padding: 6px 0;
  }
  .sect {
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-tertiary);
    padding: 10px 16px 4px;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    border: none;
    background: transparent;
    padding: 9px 16px;
    cursor: pointer;
    text-align: left;
  }
  .row:hover,
  .row.sel {
    background: var(--bg-hover);
  }
  .row-icon {
    width: 22px;
    display: inline-flex;
    justify-content: center;
    color: var(--text-secondary);
    flex-shrink: 0;
  }
  .row-text {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }
  .row-title {
    font-family: var(--font-mono);
    font-size: 14px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-sub {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .none {
    font-family: var(--font-mono);
    font-size: 13px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 30px 0;
  }
</style>
