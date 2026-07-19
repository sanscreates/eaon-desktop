<script lang="ts">
  // Port of ChatHomeView's conversation + MessageCell — 768px column, user
  // bubbles right-aligned, assistant replies with the model-attribution
  // header (brand logo + mono-11 name), the "Thinking" disclosure, markdown
  // + code rendering, hover copy/thumbs/regenerate row, and the measured
  // stats caption. Scroll-follow matches the Mac behavior: following stops
  // the moment you scroll up, resumes via the jump-to-bottom button.
  import { app } from "$lib/state.svelte";
  import type { ChatMessage, Conversation } from "$lib/types";
  import { extractReasoning, parseMessageBlocks } from "$lib/markdown";
  import { copyToClipboard } from "$lib/utils";
  import AttachmentThumb from "./AttachmentThumb.svelte";
  import BrandLogo from "./BrandLogo.svelte";
  import Icon from "./Icon.svelte";
  import MarkdownBlock from "./MarkdownBlock.svelte";
  import CodeBlock from "./CodeBlock.svelte";

  let { conversation }: { conversation: Conversation } = $props();

  let scroller = $state<HTMLElement | null>(null);
  let nearBottom = $state(true);
  let copiedId = $state<string | null>(null);
  let reactions = $state<Record<string, number>>({});
  let openThinking = $state<Set<string>>(new Set());

  const streaming = $derived(app.isGenerating(conversation.id));
  const lastId = $derived(conversation.messages[conversation.messages.length - 1]?.id);

  // Follow new content only while the user is at (or near) the bottom —
  // an upward scroll disarms following instantly (the Mac scroll-intent fix).
  $effect(() => {
    void conversation.messages.length;
    void conversation.messages[conversation.messages.length - 1]?.content;
    void conversation.messages[conversation.messages.length - 1]?.reasoning;
    if (nearBottom && scroller) {
      scroller.scrollTop = scroller.scrollHeight;
    }
  });

  function onScroll() {
    if (!scroller) return;
    nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 60;
  }

  function jumpToBottom() {
    nearBottom = true;
    scroller?.scrollTo({ top: scroller.scrollHeight, behavior: "smooth" });
  }

  async function copyMessage(message: ChatMessage) {
    const visible = extractReasoning(message.content).visibleContent;
    await copyToClipboard(visible);
    copiedId = message.id;
    setTimeout(() => (copiedId = null), 1500);
  }

  function toggleThinking(id: string) {
    const next = new Set(openThinking);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    openThinking = next;
  }

  function statsCaption(message: ChatMessage): string | null {
    if (message.role !== "assistant" || message.isError) return null;
    if (!message.generationStartTime || !message.generationEndTime || !message.generatedTokenCount) return null;
    const parts: string[] = [];
    if (message.modelId?.startsWith("ollama:")) parts.push("Ran locally · Ollama");
    parts.push(`${message.generatedTokenCount} tok`);
    const seconds = (message.generationEndTime - message.generationStartTime) / 1000;
    if (seconds > 0 && app.settings.showTokenSpeed) {
      parts.push(`${Math.round(message.generatedTokenCount / seconds)} tok/s`);
    }
    return parts.join(" · ");
  }
</script>

<div class="viewport">
  <div class="scroll" bind:this={scroller} onscroll={onScroll}>
    <div class="thread">
      {#each conversation.messages as message, index (message.id)}
        {@const isLast = message.id === lastId}
        {@const typing = streaming && isLast && message.role === "assistant"}
        {#if message.role === "user" && message.isToolResult}
          <!-- Agent tool output — a compact, collapsed card (the terminal
               turns of an agent run), matching the Mac ToolResultsCard. -->
          <div class="turn assistant">
            <details class="tool-results">
              <summary>
                <Icon name="chevron-right" size={10} stroke={2.4} />
                Tool results
              </summary>
              <pre class="tool-results-body selectable">{message.content.replace(/^\[Tool results[^\]]*\]\n\n/, "")}</pre>
            </details>
          </div>
        {:else if message.role === "user"}
          <div class="turn user">
            {#if message.attachments?.length}
              <div class="attachments">
                {#each message.attachments as attachment (attachment.id)}
                  <AttachmentThumb {attachment} />
                {/each}
              </div>
            {/if}
            {#if message.content}
              <div class="user-bubble selectable" class:accent={app.settings.coloredUserBubble}>{message.content}</div>
            {/if}
          </div>
        {:else}
          {@const extracted = extractReasoning(message.content)}
          {@const liveReasoning = message.reasoning || extracted.reasoning || ""}
          {@const blocks = parseMessageBlocks(extracted.visibleContent)}
          <div class="turn assistant">
            {#if message.modelDisplay}
              <div class="attribution">
                <BrandLogo modelId={message.modelId ?? ""} size={14} />
                <span>{message.modelDisplay}</span>
              </div>
            {/if}

            {#if liveReasoning}
              {@const stillThinking = typing && !extracted.visibleContent && !message.isError}
              <div class="thinking">
                <button class="think-head" onclick={() => toggleThinking(message.id)}>
                  <span class="think-chev" class:open={openThinking.has(message.id)}>
                    <Icon name="chevron-right" size={10} stroke={2.4} />
                  </span>
                  <span class:wave={stillThinking}>{stillThinking ? "Thinking…" : "Thinking"}</span>
                </button>
                {#if openThinking.has(message.id)}
                  <div class="think-body selectable">{liveReasoning}</div>
                {/if}
              </div>
            {/if}

            {#if message.isError}
              <div class="error-card selectable">
                <Icon name="warning" size={16} />
                <div>
                  <div class="error-title">Something went wrong</div>
                  <div class="error-body">{message.content}</div>
                </div>
              </div>
            {:else if blocks.length}
              <div class="blocks">
                {#each blocks as block, blockIndex (blockIndex)}
                  {#if block.type === "text"}
                    {#if block.content.trim()}
                      <MarkdownBlock text={block.content} />
                    {/if}
                  {:else}
                    <CodeBlock language={block.language} code={block.content} />
                  {/if}
                {/each}
              </div>
            {:else if typing && !liveReasoning}
              <div class="pulse-dot"></div>
            {/if}

            {#if message.attachments?.length}
              <!-- Generated images — shown large and prominent, the reply's
                   own artifact rather than a small thumbnail. -->
              <div class="gen-images">
                {#each message.attachments as attachment (attachment.id)}
                  <AttachmentThumb {attachment} large />
                {/each}
              </div>
            {/if}

            {#if !typing && (extracted.visibleContent || message.isError)}
              <div class="footer">
                {#if statsCaption(message)}
                  <div class="stats">{statsCaption(message)}</div>
                {/if}
                <div class="actions">
                  <button title="Copy" onclick={() => copyMessage(message)}>
                    <Icon name={copiedId === message.id ? "check" : "copy"} size={14} />
                  </button>
                  <button
                    title={app.speakingMessageId === message.id ? "Stop reading" : "Read aloud"}
                    class:lit={app.speakingMessageId === message.id}
                    onclick={() => app.toggleSpeak(message)}
                  >
                    <Icon name={app.speakingMessageId === message.id ? "stop" : "speaker"} size={14} />
                  </button>
                  <button
                    title="Good response"
                    class:lit={reactions[message.id] === 1}
                    onclick={() => (reactions[message.id] = reactions[message.id] === 1 ? 0 : 1)}
                  >
                    <Icon name="thumbs-up" size={14} />
                  </button>
                  <button
                    title="Bad response"
                    class:lit={reactions[message.id] === -1}
                    onclick={() => (reactions[message.id] = reactions[message.id] === -1 ? 0 : -1)}
                  >
                    <Icon name="thumbs-down" size={14} />
                  </button>
                  {#if index === conversation.messages.length - 1}
                    <button title="Regenerate" onclick={() => app.regenerate()}>
                      <Icon name="refresh" size={14} />
                    </button>
                  {/if}
                </div>
              </div>
            {/if}
          </div>
        {/if}
      {/each}
    </div>
  </div>

  {#if !nearBottom}
    <button class="jump" title="Jump to bottom" onclick={jumpToBottom}>
      <Icon name="arrow-down" size={14} stroke={2.2} />
    </button>
  {/if}
</div>

<style>
  .viewport {
    position: relative;
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
    padding: 12px 0;
  }
  .thread {
    max-width: 768px;
    margin: 0 auto;
    padding: 0 24px;
    display: flex;
    flex-direction: column;
    gap: 24px;
  }
  .turn {
    display: flex;
    flex-direction: column;
  }
  .turn.user {
    align-items: flex-end;
  }
  .attachments {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: 8px;
    margin-bottom: 6px;
    max-width: calc(100% - 60px);
  }
  .gen-images {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    margin-top: 8px;
  }
  .user-bubble {
    background: var(--user-bubble);
    border-radius: 12px;
    padding: 9px 14px;
    font-family: var(--font-sans);
    font-size: var(--message-font-size);
    line-height: 1.55;
    white-space: pre-wrap;
    word-break: break-word;
    max-width: calc(100% - 60px);
  }
  .user-bubble.accent {
    background: color-mix(in srgb, var(--accent-user) 15%, transparent);
  }
  .attribution {
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    margin-bottom: 6px;
  }
  .thinking {
    margin-bottom: 8px;
  }
  .think-head {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: none;
    background: transparent;
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 13px;
    cursor: pointer;
    padding: 4px 0;
  }
  .think-chev {
    display: inline-flex;
    color: var(--text-tertiary);
    transition: transform 0.16s ease;
  }
  .think-chev.open {
    transform: rotate(90deg);
  }
  .wave {
    animation: shimmer 1.4s ease-in-out infinite;
  }
  @keyframes shimmer {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.45; }
  }
  .think-body {
    margin: 8px 0 0 6px;
    padding: 0 4px 0 10px;
    border-left: 2px solid var(--border-subtle);
    color: var(--text-tertiary);
    font-family: var(--font-mono);
    font-size: 12px;
    white-space: pre-wrap;
    line-height: 1.5;
  }
  .blocks {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .tool-results {
    max-width: 560px;
    background: color-mix(in srgb, var(--bg-chip) 60%, transparent);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 8px 10px;
  }
  .tool-results summary {
    display: flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
    list-style: none;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    color: var(--text-tertiary);
  }
  .tool-results summary::-webkit-details-marker { display: none; }
  .tool-results[open] summary :global(svg) { transform: rotate(90deg); }
  .tool-results summary :global(svg) { transition: transform 0.15s ease; }
  .tool-results-body {
    margin: 8px 0 0;
    max-height: 260px;
    overflow: auto;
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-secondary);
    white-space: pre-wrap;
    word-break: break-word;
  }
  .pulse-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--text-primary);
    animation: pulse 1.4s ease-in-out infinite;
    margin: 4px 0;
  }
  @keyframes pulse {
    0%, 100% { opacity: 0.9; transform: scale(1); }
    50% { opacity: 0.25; transform: scale(0.85); }
  }
  .error-card {
    display: flex;
    gap: 10px;
    padding: 12px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--destructive) 6%, transparent);
    border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
    color: var(--destructive);
  }
  .error-title {
    font-family: var(--font-mono);
    font-size: var(--message-font-size);
    font-weight: 600;
    color: var(--text-primary);
  }
  .error-body {
    font-family: var(--font-sans);
    font-size: calc(var(--message-font-size) - 1px);
    color: var(--text-secondary);
    margin-top: 4px;
    line-height: 1.5;
  }
  .footer {
    margin-top: 4px;
  }
  .stats {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
    margin-bottom: 2px;
  }
  .actions {
    display: flex;
    gap: 2px;
    opacity: 0;
    transition: opacity 0.12s ease;
    padding-top: 2px;
  }
  .turn.assistant:hover .actions {
    opacity: 1;
  }
  .actions button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: none;
    background: transparent;
    border-radius: 7px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .actions button:hover {
    background: var(--bg-hover);
  }
  .actions button.lit {
    color: var(--text-primary);
  }
  .jump {
    position: absolute;
    right: 24px;
    bottom: 16px;
    width: 34px;
    height: 34px;
    border-radius: 50%;
    border: 1px solid var(--border-subtle);
    background: var(--bg-elevated);
    color: var(--text-primary);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    box-shadow: 0 3px 8px var(--shadow);
  }
</style>
