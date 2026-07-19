<script lang="ts">
  // One attachment on a sent message: image thumbnail (loaded from the
  // attachments store, cached) or a file chip. Mirrors the Mac app's
  // message-attachment rendering.
  import { app } from "$lib/state.svelte";
  import type { MessageAttachment } from "$lib/types";
  import Icon from "./Icon.svelte";

  let { attachment, large = false }: { attachment: MessageAttachment; large?: boolean } = $props();

  let src = $state<string | null>(null);

  $effect(() => {
    if (attachment.kind !== "image") return;
    let alive = true;
    app.attachmentPreview(attachment).then((url) => {
      if (alive) src = url;
    });
    return () => {
      alive = false;
    };
  });
</script>

{#if attachment.kind === "image"}
  {#if src}
    <img class="att-img" class:large src={src} alt={attachment.fileName} />
  {:else}
    <div class="att-img placeholder" class:large></div>
  {/if}
{:else}
  <div class="att-file">
    <span class="att-file-icon"><Icon name="folder" size={13} /></span>
    <span class="att-file-name">{attachment.fileName}</span>
  </div>
{/if}

<style>
  .att-img {
    display: block;
    max-width: 220px;
    max-height: 220px;
    border-radius: 12px;
    border: 1px solid var(--border-subtle);
    object-fit: cover;
  }
  .att-img.placeholder {
    width: 120px;
    height: 90px;
    background: var(--bg-chip);
  }
  .att-img.large {
    max-width: min(440px, 100%);
    max-height: 440px;
  }
  .att-img.placeholder.large {
    width: 300px;
    height: 220px;
  }
  .att-file {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    background: var(--bg-chip);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 7px 11px;
    max-width: 260px;
  }
  .att-file-icon {
    display: inline-flex;
    color: var(--text-secondary);
    flex-shrink: 0;
  }
  .att-file-name {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
</style>
