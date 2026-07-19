<script lang="ts">
  // Port of ChatComposer.swift — the radius-26 pill: full-width growing
  // text area on row 1 (min 46 / max 220, sans 16, "Ask <model> anything"),
  // then plus button + mode segmented control (pre-conversation only) +
  // send/stop on row 2. Notice banners float above the pill.
  import { app } from "$lib/state.svelte";
  import Icon from "./Icon.svelte";

  let input = $state("");
  let field = $state<HTMLTextAreaElement | null>(null);
  let attachOpen = $state(false);
  let photoInput = $state<HTMLInputElement | null>(null);
  let fileInput = $state<HTMLInputElement | null>(null);

  const streaming = $derived(app.currentIsGenerating);
  const hasContent = $derived(!!input.trim() || app.pendingAttachments.length > 0);
  const canSend = $derived(hasContent && !streaming && !!app.selectedModel);

  const placeholder = $derived.by(() => {
    const model = app.selectedModel;
    if (!model) return "Ask anything";
    const name = model.display.split(":")[0];
    return `Ask ${name} anything`;
  });

  // Chat and Agent only — matching the Mac switcher (EaonMode.switcherCases).
  // The wider device tools (formerly the separate Eaon Claw mode) fold into
  // Agent via Settings → Eaon Claw, exactly like macOS.
  const MODES: Array<{ id: "chat" | "agent"; label: string }> = [
    { id: "chat", label: "Chat" },
    { id: "agent", label: "Agent" },
  ];

  function autogrow() {
    if (!field) return;
    field.style.height = "auto";
    field.style.height = Math.min(Math.max(field.scrollHeight, 46), 220) + "px";
  }

  async function send() {
    if (!canSend) return;
    const text = input;
    input = "";
    await Promise.resolve();
    autogrow();
    await app.send(text);
  }

  async function onFilesPicked(list: FileList | null) {
    if (!list) return;
    for (const file of Array.from(list)) await app.addAttachment(file);
  }

  /** Pasted images (screenshots) become attachments — the Mac app's
   *  importImageFromPasteboard path. */
  async function onPaste(e: ClipboardEvent) {
    const items = e.clipboardData?.items;
    if (!items) return;
    const images = Array.from(items).filter((item) => item.kind === "file" && item.type.startsWith("image/"));
    if (!images.length) return;
    e.preventDefault();
    for (const item of images) {
      const file = item.getAsFile();
      if (file) await app.addAttachment(file);
    }
  }

  function primaryAction() {
    if (streaming) app.stopGeneration();
    else send();
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  }

  function pickMode(mode: "chat" | "agent") {
    app.mode = mode;
    app.notice = null;
  }
</script>

<div class="composer">
  {#if !app.allModels.length && !app.isLoadingModels}
    <div class="banner">
      <span class="banner-icon"><Icon name="key" size={13} /></span>
      Set up a model provider in Settings to start chatting — Aqua, your own API key, or a local model.
    </div>
  {/if}
  {#if app.notice}
    <div class="banner">
      <span class="banner-icon"><Icon name="info" size={13} /></span>
      {app.notice}
      <button class="banner-x" onclick={() => (app.notice = null)}><Icon name="xmark" size={11} /></button>
    </div>
  {/if}
  {#if app.lastError}
    <div class="banner error">
      <span class="banner-icon"><Icon name="warning" size={13} /></span>
      {app.lastError}
      <button class="banner-x" onclick={() => (app.lastError = null)}><Icon name="xmark" size={11} /></button>
    </div>
  {/if}

  <div class="pill">
    {#if app.pendingAttachments.length}
      <div class="chips">
        {#each app.pendingAttachments as attachment (attachment.id)}
          <div class="chip" class:img={attachment.kind === "image"}>
            {#if attachment.kind === "image" && app.attachmentPreviews[attachment.id]}
              <img src={app.attachmentPreviews[attachment.id]} alt={attachment.fileName} />
            {:else}
              <span class="chip-icon"><Icon name="folder" size={13} /></span>
              <span class="chip-name">{attachment.fileName}</span>
            {/if}
            <button class="chip-x" title="Remove" onclick={() => app.removePendingAttachment(attachment.id)}>
              <Icon name="xmark" size={10} stroke={2.6} />
            </button>
          </div>
        {/each}
      </div>
    {/if}
    <textarea
      bind:this={field}
      bind:value={input}
      oninput={autogrow}
      onkeydown={onKey}
      onpaste={onPaste}
      {placeholder}
      rows="1"
    ></textarea>

    <input
      bind:this={photoInput}
      type="file"
      accept="image/*"
      multiple
      hidden
      onchange={(e) => { onFilesPicked(e.currentTarget.files); e.currentTarget.value = ""; }}
    />
    <input
      bind:this={fileInput}
      type="file"
      multiple
      hidden
      onchange={(e) => { onFilesPicked(e.currentTarget.files); e.currentTarget.value = ""; }}
    />

    <div class="row">
      <div class="plus-wrap">
        <button class="plus" title="Attach" onclick={(e) => { e.stopPropagation(); attachOpen = !attachOpen; }}>
          <Icon name="plus" size={17} />
        </button>
        {#if attachOpen}
          <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
          <div class="attach-menu" onclick={(e) => e.stopPropagation()}>
            <button onclick={() => { attachOpen = false; photoInput?.click(); }}>
              <Icon name="photo" size={14} /> Add photo
            </button>
            <button onclick={() => { attachOpen = false; fileInput?.click(); }}>
              <Icon name="folder" size={14} /> Add file
            </button>
          </div>
        {/if}
      </div>

      {#if !app.current || !app.current.messages.length}
        <div class="modes">
          {#each MODES as mode}
            <button class="mode" class:sel={app.mode === mode.id} onclick={() => pickMode(mode.id)}>
              {mode.label}
            </button>
          {/each}
        </div>
      {/if}

      <span class="spacer"></span>

      <button
        class="send"
        class:stop={streaming}
        class:dim={!streaming && !hasContent}
        disabled={!streaming && !canSend}
        aria-label={streaming ? "Stop" : "Send"}
        onclick={primaryAction}
      >
        <Icon name={streaming ? "stop" : "arrow-up"} size={streaming ? 13 : 16} stroke={2.4} />
      </button>
    </div>
  </div>
</div>

<svelte:window onclick={() => (attachOpen = false)} />

<style>
  .composer {
    width: 100%;
  }
  .banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    margin-bottom: 8px;
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 1.45;
  }
  .banner-icon {
    color: #e8a838;
    display: inline-flex;
    flex-shrink: 0;
  }
  .banner.error {
    color: var(--destructive);
  }
  .banner.error .banner-icon {
    color: var(--destructive);
  }
  .banner-x {
    margin-left: auto;
    border: none;
    background: transparent;
    color: var(--text-tertiary);
    cursor: pointer;
    display: inline-flex;
    padding: 2px;
  }
  .pill {
    background: var(--bg-input);
    border: 1px solid var(--border-subtle);
    border-radius: 26px;
    box-shadow: 0 2px 6px color-mix(in srgb, var(--shadow) 16%, transparent);
  }
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    padding: 12px 18px 0;
  }
  .chip {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 7px;
    max-width: 240px;
    background: var(--bg-input-secondary);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 6px 26px 6px 9px;
  }
  .chip.img {
    padding: 0;
    overflow: hidden;
  }
  .chip.img img {
    display: block;
    width: 56px;
    height: 56px;
    object-fit: cover;
  }
  .chip-icon {
    display: inline-flex;
    color: var(--text-secondary);
    flex-shrink: 0;
  }
  .chip-name {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .chip-x {
    position: absolute;
    top: 3px;
    right: 3px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 17px;
    height: 17px;
    border-radius: 50%;
    border: none;
    background: color-mix(in srgb, var(--bg-primary) 78%, transparent);
    color: var(--text-primary);
    cursor: pointer;
  }
  .chip:not(.img) .chip-x {
    top: 50%;
    transform: translateY(-50%);
    right: 5px;
    background: transparent;
    color: var(--text-tertiary);
  }
  textarea {
    display: block;
    width: 100%;
    height: 46px;
    resize: none;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 16px;
    line-height: 1.5;
    padding: 16px 18px 0;
  }
  textarea::placeholder {
    color: var(--text-tertiary);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px 12px;
  }
  .plus-wrap {
    position: relative;
  }
  .plus {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border-radius: 50%;
    border: none;
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    opacity: 0.85;
    cursor: pointer;
    flex-shrink: 0;
  }
  .attach-menu {
    position: absolute;
    bottom: 42px;
    left: 0;
    min-width: 170px;
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    box-shadow: 0 8px 24px var(--shadow);
    padding: 4px;
    z-index: 50;
  }
  .attach-menu button {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    border: none;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 13px;
    padding: 8px 10px;
    border-radius: 8px;
    cursor: pointer;
    text-align: left;
  }
  .attach-menu button:hover {
    background: var(--bg-hover);
  }
  .modes {
    display: flex;
    gap: 2px;
    background: var(--bg-chip);
    border-radius: 999px;
    padding: 2px;
  }
  .mode {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 12px;
    padding: 5px 12px;
    border-radius: 999px;
    cursor: pointer;
  }
  .mode.sel {
    background: var(--bg-selected);
    color: var(--text-primary);
  }
  .spacer {
    flex: 1;
  }
  .send {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    border: none;
    background: var(--text-primary);
    color: var(--bg-primary);
    cursor: pointer;
    flex-shrink: 0;
  }
  .send.dim {
    opacity: 0.35;
    cursor: default;
  }
  .send.stop {
    background: var(--destructive);
    color: #fff;
    opacity: 1;
  }
</style>
