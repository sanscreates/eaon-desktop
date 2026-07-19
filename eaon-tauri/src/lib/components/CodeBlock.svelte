<script lang="ts">
  // Port of CodeBlockView.swift — header band with language label + Copy,
  // syntax-highlighted mono-13 body on the near-black code background,
  // 420px max height, radius-12 card.
  import { highlight, detectLanguageFromTag } from "$lib/highlight";
  import { copyToClipboard } from "$lib/utils";
  import Icon from "./Icon.svelte";

  let { language = null, code = "" }: { language?: string | null; code?: string } = $props();

  let copied = $state(false);

  const html = $derived(highlight(code, detectLanguageFromTag(language)));

  async function copy() {
    await copyToClipboard(code);
    copied = true;
    setTimeout(() => (copied = false), 1500);
  }
</script>

<div class="code-card">
  <div class="head">
    <span class="lang">{language || "code"}</span>
    <button class="copy" class:copied onclick={copy}>
      <Icon name={copied ? "check" : "copy"} size={12} />
      {copied ? "Copied" : "Copy"}
    </button>
  </div>
  <div class="body selectable">
    <pre><code>{@html html}</code></pre>
  </div>
</div>

<style>
  .code-card {
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    overflow: hidden;
    margin: 6px 0;
  }
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px;
    background: var(--bg-code-header);
  }
  .lang {
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 500;
    color: var(--text-secondary);
  }
  .copy {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    border: none;
    background: transparent;
    color: var(--text-primary);
    opacity: 0.75;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
  }
  .copy:hover {
    opacity: 1;
  }
  .copy.copied {
    color: var(--diff-added);
    opacity: 1;
  }
  .body {
    background: var(--bg-code);
    max-height: 420px;
    overflow: auto;
  }
  pre {
    margin: 0;
    padding: 14px;
  }
  code {
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 1.5;
    color: var(--text-code);
    white-space: pre;
  }
</style>
