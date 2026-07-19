<script lang="ts">
  // Port of BrandLogoView — the real brand asset when one exists, otherwise
  // a neutral monogram chip so unknown models never render broken images.
  import { app } from "$lib/state.svelte";
  import { brandForModel, logoPath, type Brand } from "$lib/brand";

  let {
    modelId = "",
    brand = null,
    size = 16,
  }: { modelId?: string; brand?: Brand | null; size?: number } = $props();

  const resolved = $derived(brand ?? brandForModel(modelId));
  const isDark = $derived(
    app.settings.theme === "Dark" ||
      (app.settings.theme === "System" && window.matchMedia("(prefers-color-scheme: dark)").matches)
  );
  const src = $derived(logoPath(resolved, isDark));
</script>

{#if src}
  <img {src} alt={resolved.company} width={size} height={size} style="object-fit: contain;" draggable="false" />
{:else}
  <span
    class="monogram"
    style="width:{size}px;height:{size}px;font-size:{Math.round(size * 0.55)}px;"
  >{resolved.company.slice(0, 1).toUpperCase()}</span>
{/if}

<style>
  .monogram {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 30%;
    background: var(--bg-chip-secondary);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-weight: 600;
  }
</style>
