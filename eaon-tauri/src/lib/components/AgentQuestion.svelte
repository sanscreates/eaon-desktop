<script lang="ts">
  // The Agent's ask_user dialog — mirrors the macOS AgentQuestionDialog:
  // the model's question, one button per offered option, and a free-text
  // field so the user can always answer in their own words instead.
  import { app } from "$lib/state.svelte";
  import Icon from "./Icon.svelte";

  const pending = $derived(app.pendingAgentQuestion);
  let custom = $state("");

  function answer(text: string) {
    const trimmed = text.trim();
    if (!trimmed) return;
    custom = "";
    app.pendingAgentQuestion?.resolve(trimmed);
  }
</script>

{#if pending}
  <div class="overlay">
    <div class="card">
      <div class="title">
        <span class="mark"><Icon name="info" size={16} /></span>
        Eaon has a question
      </div>
      <p class="question">{pending.question}</p>
      {#if pending.options.length}
        <div class="options">
          {#each pending.options as option (option)}
            <button class="option" onclick={() => answer(option)}>{option}</button>
          {/each}
        </div>
      {/if}
      <div class="custom">
        <input
          bind:value={custom}
          placeholder="Or type your own answer…"
          onkeydown={(e) => { if (e.key === "Enter") answer(custom); }}
        />
        <button class="send" disabled={!custom.trim()} onclick={() => answer(custom)}>Answer</button>
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
  .mark { color: var(--accent-user); display: inline-flex; }
  .question {
    font-family: var(--font-sans);
    font-size: 15px;
    color: var(--text-primary);
    line-height: 1.5;
    margin: 0 0 16px;
  }
  .options {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-bottom: 16px;
  }
  .option {
    text-align: left;
    font-family: var(--font-sans);
    font-size: 14px;
    color: var(--text-primary);
    background: var(--bg-input-secondary);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 10px 14px;
    cursor: pointer;
  }
  .option:hover { border-color: var(--border-medium); background: var(--bg-hover); }
  .custom {
    display: flex;
    gap: 8px;
  }
  .custom input {
    flex: 1;
    font-family: var(--font-sans);
    font-size: 13.5px;
    color: var(--text-primary);
    background: var(--bg-input);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 9px 12px;
    outline: none;
  }
  .custom input:focus { border-color: var(--border-medium); }
  .send {
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    padding: 8px 16px;
    border-radius: 10px;
    border: 1px solid transparent;
    background: var(--accent);
    color: var(--accent-fg, #fff);
    cursor: pointer;
  }
  .send:disabled { opacity: 0.5; cursor: default; }
</style>
