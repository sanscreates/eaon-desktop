<script lang="ts">
  // Port of ModelPickerPopover.swift — the capsule trigger (brand logo with
  // a green "runs locally" dot, mono-14 name, up/down chevron) and the
  // 340×480 popover: search field, Favorites, "On this PC" local section,
  // then one group per real connection with a gear to its settings page.
  import { app } from "$lib/state.svelte";
  import type { ModelEntry } from "$lib/types";
  import BrandLogo from "./BrandLogo.svelte";
  import Icon from "./Icon.svelte";

  let open = $state(false);
  let query = $state("");
  let searchField = $state<HTMLInputElement | null>(null);

  const selected = $derived(app.selectedModel);
  const q = $derived(query.trim().toLowerCase());

  const favorites = $derived(
    q ? [] : app.allModels.filter((m) => app.settings.favorites.includes(m.key))
  );
  const matches = (m: ModelEntry) =>
    !q || m.display.toLowerCase().includes(q) || m.requestId.toLowerCase().includes(q);

  const localModels = $derived(app.allModels.filter((m) => m.provider.kind === "ollama" && matches(m)));
  const aquaGroup = $derived(app.allModels.filter((m) => m.provider.kind === "aqua" && matches(m)));
  const customGroups = $derived(
    app.settings.customProviders
      .map((config) => ({
        config,
        models: app.allModels.filter(
          (m) => m.provider.kind === "custom" && m.provider.configId === config.id && matches(m)
        ),
      }))
      .filter((g) => !q || g.models.length)
  );

  function pick(model: ModelEntry) {
    app.selectModel(model.key);
    open = false;
  }

  function openSettings(page: string) {
    open = false;
    app.settingsPage = page;
    app.settingsOpen = true;
  }

  function toggle(event: MouseEvent) {
    event.stopPropagation();
    open = !open;
    if (open) {
      query = "";
      setTimeout(() => searchField?.focus(), 30);
    }
  }
</script>

<svelte:window onclick={() => (open = false)} />

<div class="wrap">
  <button class="trigger" class:placeholder={!selected} onclick={toggle} disabled={app.isLoadingModels && !app.allModels.length}>
    {#if selected}
      <span class="logo-wrap">
        <BrandLogo modelId={selected.requestId} size={20} />
        {#if selected.provider.kind === "ollama"}
          <span class="local-dot" title="Running locally on this PC"></span>
        {/if}
      </span>
    {/if}
    <span class="name">
      {app.isLoadingModels && !app.allModels.length
        ? "Loading models…"
        : selected?.display ?? "Select a model"}
    </span>
    <Icon name="chevron-updown" size={12} stroke={2.4} />
  </button>

  {#if open}
    <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
    <div class="popover" onclick={(e) => e.stopPropagation()}>
      <div class="search">
        <Icon name="search" size={13} />
        <input bind:this={searchField} bind:value={query} placeholder="Search models..." />
      </div>

      <div class="list">
        {#if !app.allModels.length}
          <div class="empty">No models available</div>
        {:else}
          {#if favorites.length}
            <div class="sect"><span class="star"><Icon name="star-fill" size={11} /></span> Favorites</div>
            {#each favorites as model (model.key)}
              {@render row(model)}
            {/each}
            <div class="divider"></div>
          {/if}

          {#if localModels.length}
            <div class="sect"><Icon name="laptop" size={12} /> On this PC</div>
            {#each localModels as model (model.key)}
              {@render row(model)}
            {/each}
            <div class="divider"></div>
          {/if}

          {#if aquaGroup.length || (!q && app.settings.aquaApiKey)}
            <div class="group-head">
              <span class="badge"><Icon name="drop" size={12} /></span>
              <span class="group-title">Aqua Devs</span>
              <button class="gear" title="Aqua Devs settings" onclick={() => openSettings("aqua")}>
                <Icon name="gear-fill" size={12} />
              </button>
            </div>
            {#each aquaGroup as model (model.key)}
              {@render row(model)}
            {/each}
          {/if}

          {#each customGroups as group (group.config.id)}
            <div class="group-head">
              <span class="badge mono-badge">{group.config.displayName.slice(0, 1).toUpperCase()}</span>
              <span class="group-title">{group.config.displayName}</span>
              <button class="gear" title="{group.config.displayName} settings" onclick={() => openSettings(`custom:${group.config.id}`)}>
                <Icon name="gear-fill" size={12} />
              </button>
            </div>
            {#if group.models.length}
              {#each group.models as model (model.key)}
                {@render row(model)}
              {/each}
            {:else}
              <div class="note">No models configured yet.</div>
            {/if}
          {/each}

          {#if q && !favorites.length && !localModels.length && !aquaGroup.length && !customGroups.length}
            <div class="empty">No models match your search</div>
          {/if}
        {/if}
      </div>
    </div>
  {/if}
</div>

{#snippet row(model: ModelEntry)}
  <div class="row-wrap">
    <button
      class="row"
      class:selected={app.selectedModelKey === model.key}
      onclick={() => pick(model)}
    >
      <span class="chip"><BrandLogo modelId={model.requestId} size={16} /></span>
      <span class="row-name">{model.display}</span>
      {#if model.tier?.toLowerCase() === "premium"}
        <span class="pro">PRO</span>
      {/if}
      <span class="row-spacer"></span>
    </button>
    <button
      class="fav"
      class:on={app.settings.favorites.includes(model.key)}
      title={app.settings.favorites.includes(model.key) ? "Remove from favorites" : "Add to favorites"}
      onclick={(e) => {
        e.stopPropagation();
        app.toggleFavorite(model.key);
      }}
    >
      <Icon name={app.settings.favorites.includes(model.key) ? "star-fill" : "star"} size={12} />
    </button>
  </div>
{/snippet}

<style>
  .wrap {
    position: relative;
  }
  .trigger {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 12px 7px 8px;
    border-radius: 999px;
    border: 1px solid var(--border-subtle);
    background: var(--bg-elevated);
    color: var(--text-primary);
    font-family: var(--font-mono);
    cursor: pointer;
  }
  .trigger.placeholder {
    padding-left: 14px;
  }
  .trigger:hover {
    background: var(--bg-input-secondary);
  }
  .trigger :global(svg:last-child) {
    color: var(--text-tertiary);
  }
  .logo-wrap {
    position: relative;
    display: inline-flex;
  }
  .local-dot {
    position: absolute;
    right: -2px;
    bottom: -2px;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #34c759;
    border: 1.5px solid var(--bg-elevated);
  }
  .name {
    font-size: 14px;
    font-weight: 500;
    max-width: 300px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .popover {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    width: 340px;
    height: 480px;
    display: flex;
    flex-direction: column;
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 14px;
    box-shadow: 0 16px 48px var(--shadow);
    z-index: 60;
    overflow: hidden;
  }
  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 12px 12px 8px;
    padding: 10px 12px;
    background: var(--bg-input-secondary);
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    color: var(--text-tertiary);
  }
  .search input {
    flex: 1;
    border: none;
    outline: none;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 14px;
  }
  .list {
    flex: 1;
    overflow-y: auto;
    padding: 0 8px 10px;
  }
  .sect {
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    color: var(--text-secondary);
    padding: 8px 8px 6px;
  }
  .sect .star {
    color: #eac54f;
    display: inline-flex;
  }
  .divider {
    height: 1px;
    background: var(--border-subtle);
    margin: 6px 8px;
  }
  .group-head {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 14px 8px 6px;
  }
  .badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 6px;
    background: var(--bg-subtle);
    color: var(--accent);
  }
  .mono-badge {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary);
  }
  .group-title {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .gear {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border: none;
    border-radius: 6px;
    background: var(--bg-subtle);
    color: var(--text-secondary);
    cursor: pointer;
  }
  .gear:hover {
    background: var(--bg-hover);
  }
  .row-wrap {
    position: relative;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    border: none;
    background: transparent;
    border-radius: 10px;
    padding: 7px 8px;
    cursor: pointer;
    color: var(--text-primary);
    text-align: left;
  }
  .row:hover {
    background: var(--bg-hover);
  }
  .row.selected {
    background: var(--bg-selected);
  }
  .chip {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 8px;
    background: var(--bg-subtle);
    flex-shrink: 0;
  }
  .row-name {
    font-family: var(--font-mono);
    font-size: 14px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .pro {
    font-family: var(--font-mono);
    font-size: 9px;
    font-weight: 700;
    color: var(--text-secondary);
    background: var(--bg-subtle);
    border-radius: 5px;
    padding: 3px 6px;
  }
  .row-spacer {
    flex: 1;
    min-width: 24px;
  }
  .fav {
    position: absolute;
    right: 10px;
    top: 50%;
    transform: translateY(-50%);
    display: none;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: none;
    background: transparent;
    color: var(--text-tertiary);
    cursor: pointer;
  }
  .row-wrap:hover .fav,
  .fav.on {
    display: inline-flex;
  }
  .fav.on {
    color: #eac54f;
  }
  .note,
  .empty {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-tertiary);
    padding: 8px;
  }
  .empty {
    text-align: center;
    padding: 40px 8px;
    font-size: 13px;
  }
</style>
