<script lang="ts">
  // Port of ChatHomeView.swift — 50px top bar (sidebar re-open when
  // collapsed, leading model picker, share), mode-framed empty states with
  // the centered composer, and the conversation + docked composer +
  // disclaimer once messages exist.
  import { app } from "$lib/state.svelte";
  import { copyToClipboard } from "$lib/utils";
  import Icon from "./Icon.svelte";
  import ModelPicker from "./ModelPicker.svelte";
  import Composer from "./Composer.svelte";
  import Messages from "./Messages.svelte";
  import WindowControls from "./WindowControls.svelte";

  let shared = $state(false);

  const conversation = $derived(app.current);
  const isEmpty = $derived(!conversation || conversation.messages.length === 0);

  const MODE_META = {
    chat: { title: "Chat", blurb: "Just talk — ask anything.", icon: "message" },
    agent: { title: "Agent", blurb: "Build, run, and debug real code on your PC.", icon: "terminal" },
    claw: { title: "Eaon Claw", blurb: "Let Eaon control your PC and browser to get real tasks done.", icon: "desktop" },
  } as const;

  async function shareTranscript() {
    if (!conversation) return;
    const text = conversation.messages
      .map((m) => `${m.role === "user" ? "You" : m.modelDisplay ?? "Eaon"}: ${m.content}`)
      .join("\n\n");
    await copyToClipboard(text);
    shared = true;
    setTimeout(() => (shared = false), 1500);
  }
</script>

<div class="chat-home">
  <div class="topbar" data-tauri-drag-region>
    {#if !app.sidebarOpen}
      <button class="icon-btn" title="Show sidebar" onclick={() => (app.sidebarOpen = true)}>
        <Icon name="sidebar" size={16} />
      </button>
    {/if}
    <ModelPicker />
    <span class="drag-space" data-tauri-drag-region></span>
    {#if !isEmpty}
      <button class="icon-btn" title="Copy transcript" onclick={shareTranscript}>
        <Icon name={shared ? "check" : "share"} size={15} />
      </button>
    {/if}
    <WindowControls />
  </div>

  {#if isEmpty}
    <div class="stage">
      {#if app.mode === "chat"}
        <h1 class="hero">What can I help with?</h1>
      {:else}
        {@const meta = MODE_META[app.mode]}
        <div class="mode-hero">
          <span class="mode-icon"><Icon name={meta.icon} size={30} stroke={1.9} /></span>
          <h1 class="mode-title">{meta.title}</h1>
          <p class="mode-blurb">{meta.blurb}</p>
        </div>
      {/if}
      <div class="composer-col">
        <Composer />
      </div>
    </div>
  {:else if conversation}
    <Messages {conversation} />
    <div class="dock">
      <div class="composer-col">
        <Composer />
      </div>
      <p class="disclaimer">Eaon can make mistakes. Check important info.</p>
    </div>
  {/if}
</div>

<style>
  .chat-home {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--bg-primary);
  }
  .topbar {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 50px;
    padding: 10px 14px 0;
    flex-shrink: 0;
  }
  .drag-space {
    flex: 1;
    height: 100%;
  }
  .icon-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border: none;
    background: transparent;
    border-radius: 999px;
    color: var(--text-primary);
    opacity: 0.85;
    cursor: pointer;
  }
  .icon-btn:hover {
    background: var(--bg-hover);
  }
  .stage {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 0 24px 10vh;
  }
  .hero {
    font-family: var(--font-mono);
    font-size: 34px;
    font-weight: 700;
    color: var(--text-primary);
    margin: 0 0 26px;
    text-align: center;
  }
  .mode-hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    margin-bottom: 26px;
  }
  .mode-icon {
    color: var(--text-secondary);
  }
  .mode-title {
    font-family: var(--font-mono);
    font-size: 30px;
    font-weight: 700;
    margin: 0;
    color: var(--text-primary);
  }
  .mode-blurb {
    font-family: var(--font-sans);
    font-size: 14px;
    color: var(--text-tertiary);
    margin: 0;
    text-align: center;
  }
  .composer-col {
    width: 100%;
    max-width: 768px;
  }
  .dock {
    flex-shrink: 0;
    padding: 4px 24px 0;
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  .disclaimer {
    text-align: center;
    color: var(--text-tertiary);
    font-family: var(--font-sans);
    font-size: 11px;
    margin: 8px 0;
  }
</style>
