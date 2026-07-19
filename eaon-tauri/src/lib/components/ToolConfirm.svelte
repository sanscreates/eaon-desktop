<script lang="ts">
  // Agent Sandboxed-mode confirmation — mirrors the macOS
  // DesktopCallConfirmationDialog. Shown when the Agent wants to run a
  // file/shell tool and the user hasn't turned on "always allow".
  import { app } from "$lib/state.svelte";
  import Icon from "./Icon.svelte";

  const pending = $derived(app.pendingToolConfirm);
</script>

{#if pending}
  <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
  <div class="overlay" onclick={() => app.respondToToolConfirm("deny")}>
    <div class="card" onclick={(e) => e.stopPropagation()}>
      <div class="title">
        <span class="warn"><Icon name="warning" size={16} /></span>
        Allow this action on your computer?
      </div>
      <p class="summary">{pending.summary}</p>
      {#if pending.detail}
        <pre class="detail">{pending.detail}</pre>
      {/if}
      <p class="body">
        This runs on your computer with your permissions — real, and not undone by closing the app.
        "Allow for This Chat" stops the asking for the rest of this conversation.
      </p>
      <div class="actions">
        <button class="btn secondary" onclick={() => app.respondToToolConfirm("deny")}>Don't Allow</button>
        <span class="spacer"></span>
        <button class="btn secondary" onclick={() => app.respondToToolConfirm("always")}>Allow for This Chat</button>
        <button class="btn primary" onclick={() => app.respondToToolConfirm("once")}>Allow</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: var(--bg-overlay);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 120;
  }
  .card {
    width: 460px;
    max-width: calc(100vw - 48px);
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 20px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.3);
    padding: 24px;
    animation: pop 0.18s ease-out;
  }
  @keyframes pop {
    from { transform: scale(0.94); opacity: 0; }
    to { transform: scale(1); opacity: 1; }
  }
  .title {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: var(--font-mono);
    font-size: 18px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 14px;
  }
  .warn { color: #e8a838; display: inline-flex; }
  .summary {
    font-family: var(--font-sans);
    font-size: 15px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0 0 10px;
  }
  .detail {
    max-height: 160px;
    overflow: auto;
    background: var(--bg-input);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    padding: 10px;
    margin: 0 0 14px;
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-secondary);
    white-space: pre-wrap;
    word-break: break-word;
  }
  .body {
    font-family: var(--font-sans);
    font-size: 13px;
    color: var(--text-secondary);
    line-height: 1.55;
    margin: 0 0 22px;
  }
  .actions { display: flex; align-items: center; gap: 10px; }
  .spacer { flex: 1; }
  .btn {
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    padding: 8px 16px;
    border-radius: 10px;
    border: 1px solid var(--border-subtle);
    cursor: pointer;
  }
  .btn.secondary { background: var(--bg-input-secondary); color: var(--text-primary); }
  .btn.primary { background: var(--accent); color: var(--accent-fg, #fff); border-color: transparent; }
</style>
