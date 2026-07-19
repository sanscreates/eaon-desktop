<script lang="ts">
  // Port of ModelLibraryView.swift — "Models" header + blurb, search bar,
  // collapsible curated categories from the same CuratedOllamaModels.json
  // the Mac app bundles ("Popular" open by default), rows with brand badge,
  // blurb, size and a real Download button with live pull progress, plus
  // the "On this PC" installed section with verified deletion.
  import catalog from "$lib/data/CuratedOllamaModels.json";
  import { app } from "$lib/state.svelte";
  import { brandFromCatalogKey } from "$lib/brand";
  import { formatBytes } from "$lib/utils";
  import BrandLogo from "./BrandLogo.svelte";
  import Icon from "./Icon.svelte";
  import WindowControls from "./WindowControls.svelte";

  interface CuratedEntry {
    name: string;
    blurb: string;
    approxSize: string;
    sizeBytes: number;
    brand?: string | null;
    category: string;
    isNew?: boolean;
  }

  const categoryOrder: string[] = (catalog as any).categoryOrder;
  const models: CuratedEntry[] = (catalog as any).models;

  let query = $state("");
  let expanded = $state<Set<string>>(new Set(["Popular"]));

  const q = $derived(query.trim().toLowerCase());
  const installedNames = $derived(new Set(app.ollamaModels.map((m) => m.name.replace(/:latest$/, ""))));

  const visibleByCategory = $derived.by(() => {
    const map = new Map<string, CuratedEntry[]>();
    for (const category of categoryOrder) map.set(category, []);
    for (const entry of models) {
      if (q && !entry.name.toLowerCase().includes(q) && !entry.blurb.toLowerCase().includes(q)) continue;
      map.get(entry.category)?.push(entry);
    }
    return map;
  });

  function toggleCategory(category: string) {
    const next = new Set(expanded);
    if (next.has(category)) next.delete(category);
    else next.add(category);
    expanded = next;
  }

  function isInstalled(name: string): boolean {
    const bare = name.replace(/:latest$/, "");
    return installedNames.has(bare) || app.ollamaModels.some((m) => m.name === name || m.name === `${name}:latest`);
  }

  function progressLabel(name: string): string {
    const pull = app.pulls[name];
    if (!pull) return "";
    if (pull.error) return pull.error;
    if (pull.total > 0) {
      const pct = Math.floor((pull.completed / pull.total) * 100);
      return `${pct}% · ${formatBytes(pull.completed)} of ${formatBytes(pull.total)}`;
    }
    return pull.status || "starting…";
  }

  let customPull = $state("");
</script>

<div class="page">
  <div class="head" data-tauri-drag-region>
    <div class="head-text">
      <h1>Models</h1>
      <p>Download open models and run them privately on this PC — no API key, no internet once they're here.</p>
    </div>
    <WindowControls />
  </div>

  <div class="scroll">
    <div class="inner">
      <div class="toolbar">
        <div class="seg">
          <button class="seg-btn sel">Ollama</button>
          <button class="seg-btn" onclick={() => (app.notice = "Hugging Face downloads are coming to the Windows version soon.")}>Hugging Face</button>
        </div>
        <div class="search">
          <Icon name="search" size={13} />
          <input bind:value={query} placeholder="Any name from ollama.com/library…" />
        </div>
      </div>

      {#if !app.ollamaReachable}
        <div class="warn-card">
          <Icon name="warning" size={15} />
          <div>
            <div class="warn-title">Ollama isn't running</div>
            <div class="warn-sub">Install it from ollama.com and start it — then models download and run fully on this PC.</div>
          </div>
          <button class="ghost-btn" onclick={() => app.refreshModels()}>Retry</button>
        </div>
      {/if}

      {#if q && ![...visibleByCategory.values()].some((list) => list.length)}
        <div class="pull-custom">
          <span class="mono">{query.trim()}</span>
          {#if app.pulls[query.trim()]}
            <span class="progress">{progressLabel(query.trim())}</span>
          {:else}
            <button class="dl-btn" onclick={() => app.pullModel(query.trim())}>
              <Icon name="download" size={13} /> Download
            </button>
          {/if}
        </div>
      {/if}

      {#each categoryOrder as category (category)}
        {@const list = visibleByCategory.get(category) ?? []}
        {#if list.length}
          <div class="cat-block">
            <button class="cat-head" onclick={() => toggleCategory(category)}>
              <span class="chev" class:open={expanded.has(category) || !!q}>
                <Icon name="chevron-right" size={11} stroke={2.4} />
              </span>
              <span class="cat-name">{category}</span>
              <span class="cat-count">{list.length}</span>
            </button>
            {#if expanded.has(category) || q}
              <div class="rows">
                {#each list as entry (category + entry.name)}
                  <div class="row">
                    <span class="badge">
                      <BrandLogo brand={brandFromCatalogKey(entry.brand)} modelId={entry.name} size={17} />
                    </span>
                    <div class="row-main">
                      <div class="row-title">
                        <span class="mono">{entry.name}</span>
                        <span class="size">≈{entry.approxSize.replace("≈", "")}</span>
                        {#if entry.isNew}<span class="new">NEW</span>{/if}
                      </div>
                      <div class="row-blurb">{entry.blurb}</div>
                      {#if app.pulls[entry.name]}
                        <div class="progress-wrap">
                          {#if app.pulls[entry.name].error}
                            <span class="pull-error">{app.pulls[entry.name].error}</span>
                            <button class="mini-x" onclick={() => app.dismissPullError(entry.name)}><Icon name="xmark" size={11} /></button>
                          {:else}
                            <div class="bar">
                              <div
                                class="fill"
                                style="width:{app.pulls[entry.name].total ? (app.pulls[entry.name].completed / app.pulls[entry.name].total) * 100 : 4}%"
                              ></div>
                            </div>
                            <span class="progress">{progressLabel(entry.name)}</span>
                          {/if}
                        </div>
                      {/if}
                    </div>
                    {#if isInstalled(entry.name)}
                      <span class="installed"><Icon name="check-circle-fill" size={14} /> Installed</span>
                      <button class="chat-btn" onclick={() => {
                        const match = app.ollamaModels.find((m) => m.name === entry.name || m.name === `${entry.name}:latest`);
                        if (match) { app.selectModel(`ollama:${match.name}`); app.newChat(); }
                      }}>Chat</button>
                    {:else if !app.pulls[entry.name]}
                      <button class="dl-btn" disabled={!app.ollamaReachable} onclick={() => app.pullModel(entry.name)}>
                        <Icon name="download" size={13} /> Download
                      </button>
                    {/if}
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        {/if}
      {/each}

      {#if app.ollamaModels.length}
        <div class="cat-block">
          <div class="cat-head static">
            <Icon name="laptop" size={13} />
            <span class="cat-name">On this PC</span>
            <span class="cat-count">{app.ollamaModels.length}</span>
          </div>
          <div class="rows">
            {#each app.ollamaModels as model (model.name)}
              <div class="row">
                <span class="badge"><BrandLogo modelId={model.name} size={17} /></span>
                <div class="row-main">
                  <div class="row-title"><span class="mono">{model.name}</span></div>
                  <div class="row-blurb">
                    Ollama · {formatBytes(model.sizeBytes)}{model.paramSize ? ` · ${model.paramSize}` : ""}{model.quantization ? ` · ${model.quantization}` : ""}
                  </div>
                </div>
                <button class="chat-btn" onclick={() => { app.selectModel(`ollama:${model.name}`); app.newChat(); }}>Chat</button>
                <button class="mini-trash" title="Delete from this PC" onclick={() => (app.dialog = { kind: "deleteModel", name: model.name })}>
                  <Icon name="trash" size={13} />
                </button>
              </div>
            {/each}
          </div>
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  .page {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--bg-primary);
  }
  .head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding: 18px 14px 0 24px;
    flex-shrink: 0;
  }
  h1 {
    font-family: var(--font-mono);
    font-size: 22px;
    font-weight: 700;
    margin: 0;
  }
  .head-text p {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin: 6px 0 0;
    max-width: 480px;
    line-height: 1.5;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
  }
  .inner {
    padding: 16px 24px 32px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    max-width: 860px;
  }
  .toolbar {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .seg {
    display: flex;
    gap: 2px;
    background: var(--bg-chip);
    border-radius: 999px;
    padding: 2px;
    flex-shrink: 0;
  }
  .seg-btn {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 12.5px;
    padding: 7px 14px;
    border-radius: 999px;
    cursor: pointer;
  }
  .seg-btn.sel {
    background: var(--bg-selected);
    color: var(--text-primary);
  }
  .search {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 9px 14px;
    background: var(--bg-input-secondary);
    border: 1px solid var(--border-subtle);
    border-radius: 999px;
    color: var(--text-tertiary);
  }
  .search input {
    flex: 1;
    border: none;
    outline: none;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 13px;
  }
  .warn-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    border-radius: 10px;
    background: color-mix(in srgb, #e8a838 8%, transparent);
    border: 1px solid color-mix(in srgb, #e8a838 30%, transparent);
    color: #e8a838;
  }
  .warn-title {
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .warn-sub {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
  }
  .warn-card .ghost-btn {
    margin-left: auto;
  }
  .pull-custom {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    background: var(--bg-elevated);
    border: 1px solid var(--border-medium);
    border-radius: 10px;
  }
  .cat-block {
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    overflow: hidden;
    background: var(--bg-elevated);
  }
  .cat-head {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    border: none;
    background: transparent;
    padding: 12px 14px;
    cursor: pointer;
    color: var(--text-primary);
    text-align: left;
  }
  .cat-head.static {
    cursor: default;
    color: var(--text-secondary);
  }
  .chev {
    display: inline-flex;
    color: var(--text-tertiary);
    transition: transform 0.15s ease;
  }
  .chev.open {
    transform: rotate(90deg);
  }
  .cat-name {
    font-family: var(--font-mono);
    font-size: 14px;
    font-weight: 600;
    flex: 1;
  }
  .cat-count {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .rows {
    border-top: 1px solid var(--border-subtle);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 11px 14px;
    border-bottom: 1px solid var(--border-subtle);
  }
  .row:last-child {
    border-bottom: none;
  }
  .badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    border-radius: 8px;
    background: var(--bg-subtle);
    flex-shrink: 0;
  }
  .row-main {
    flex: 1;
    min-width: 0;
  }
  .row-title {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .mono {
    font-family: var(--font-mono);
    font-size: 13.5px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .size {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .new {
    font-family: var(--font-mono);
    font-size: 8.5px;
    font-weight: 700;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 14%, transparent);
    border-radius: 4px;
    padding: 2px 5px;
  }
  .row-blurb {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .progress-wrap {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-top: 7px;
  }
  .bar {
    flex: 0 0 220px;
    height: 5px;
    border-radius: 3px;
    background: var(--bg-subtle);
    overflow: hidden;
  }
  .fill {
    height: 100%;
    background: var(--accent);
    border-radius: 3px;
    transition: width 0.3s ease;
  }
  .progress {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .pull-error {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--destructive);
  }
  .mini-x {
    border: none;
    background: transparent;
    color: var(--text-tertiary);
    cursor: pointer;
    display: inline-flex;
    padding: 2px;
  }
  .installed {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--diff-added);
    flex-shrink: 0;
  }
  .dl-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: none;
    border-radius: 999px;
    background: var(--text-primary);
    color: var(--bg-primary);
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    padding: 7px 14px;
    cursor: pointer;
    flex-shrink: 0;
  }
  .dl-btn:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .chat-btn {
    border: 1px solid var(--border-medium);
    border-radius: 999px;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 12px;
    padding: 6px 14px;
    cursor: pointer;
    flex-shrink: 0;
  }
  .chat-btn:hover {
    background: var(--bg-hover);
  }
  .ghost-btn {
    border: 1px solid var(--border-medium);
    border-radius: 999px;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 12px;
    padding: 6px 14px;
    cursor: pointer;
  }
  .mini-trash {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    display: inline-flex;
    padding: 6px;
    border-radius: 6px;
    flex-shrink: 0;
  }
  .mini-trash:hover {
    background: var(--bg-hover);
    color: var(--destructive);
  }
</style>
