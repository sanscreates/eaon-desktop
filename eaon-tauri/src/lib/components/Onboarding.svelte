<script lang="ts">
  // First-run welcome — the condensed cross-platform port of the Mac app's
  // OnboardingView: same copy and structure (welcome → the modes → how
  // models run), one card instead of a paged sheet.
  import { app } from "$lib/state.svelte";
  import Icon from "./Icon.svelte";

  function finish(page?: string) {
    app.settings.hasSeenOnboarding = true;
    app.saveSoon();
    if (page) {
      app.settingsPage = page;
      app.settingsOpen = true;
    }
  }
</script>

{#if !app.settings.hasSeenOnboarding}
  <div class="overlay">
    <div class="card">
      <div class="mark"><Icon name="drop" size={30} /></div>
      <h1>Welcome to Eaon</h1>
      <p class="lede">
        A chat client that isn't locked into one provider. Use Eaon's hosted models, bring your own
        API key, or run open models entirely on this PC — same app, same conversations, either way.
      </p>

      <div class="rows">
        <div class="row">
          <span class="row-icon"><Icon name="message" size={16} /></span>
          <div>
            <div class="row-title">Chat &amp; Agent</div>
            <div class="row-sub">Chat is conversation. Agent writes real files on this PC, runs them, and fixes them until they work.</div>
          </div>
        </div>
        <div class="row">
          <span class="row-icon"><Icon name="laptop" size={16} /></span>
          <div>
            <div class="row-title">Run models locally</div>
            <div class="row-sub">Pull open models with Ollama and chat fully offline — nothing leaves this PC.</div>
          </div>
        </div>
        <div class="row">
          <span class="row-icon"><Icon name="key" size={16} /></span>
          <div>
            <div class="row-title">Or connect a key</div>
            <div class="row-sub">An Aqua key or any OpenAI-compatible provider of your own. Switch or mix anytime in Settings.</div>
          </div>
        </div>
      </div>

      <div class="actions">
        <button class="btn secondary" onclick={() => finish("aqua")}>Set up a provider</button>
        <button class="btn primary" onclick={() => finish()}>Get started</button>
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
    z-index: 140;
  }
  .card {
    width: 520px;
    max-width: calc(100vw - 48px);
    max-height: calc(100vh - 48px);
    overflow-y: auto;
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 24px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.35);
    padding: 36px;
    animation: pop 0.22s ease-out;
    text-align: center;
  }
  @keyframes pop {
    from { transform: scale(0.94); opacity: 0; }
    to { transform: scale(1); opacity: 1; }
  }
  .mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 64px;
    height: 64px;
    border-radius: 18px;
    background: var(--bg-chip);
    color: var(--text-primary);
    margin-bottom: 18px;
  }
  h1 {
    font-family: var(--font-mono);
    font-size: 24px;
    font-weight: 700;
    color: var(--text-primary);
    margin: 0 0 10px;
  }
  .lede {
    font-family: var(--font-sans);
    font-size: 13.5px;
    color: var(--text-secondary);
    line-height: 1.6;
    margin: 0 0 24px;
  }
  .rows {
    display: flex;
    flex-direction: column;
    gap: 14px;
    text-align: left;
    margin-bottom: 28px;
  }
  .row {
    display: flex;
    gap: 12px;
    align-items: flex-start;
  }
  .row-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border-radius: 10px;
    background: var(--bg-chip);
    color: var(--text-primary);
    flex-shrink: 0;
  }
  .row-title {
    font-family: var(--font-mono);
    font-size: 13.5px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 2px;
  }
  .row-sub {
    font-family: var(--font-sans);
    font-size: 12.5px;
    color: var(--text-secondary);
    line-height: 1.5;
  }
  .actions {
    display: flex;
    justify-content: center;
    gap: 10px;
  }
  .btn {
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    padding: 10px 20px;
    border-radius: 12px;
    border: 1px solid var(--border-subtle);
    cursor: pointer;
  }
  .btn.secondary { background: var(--bg-input-secondary); color: var(--text-primary); }
  .btn.primary { background: var(--accent); color: var(--accent-fg, #fff); border-color: transparent; }
</style>
