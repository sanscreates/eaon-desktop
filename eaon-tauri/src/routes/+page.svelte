<script lang="ts">
  // Port of RootView.swift — the floating sidebar card beside the detail
  // surface (Chat / Projects / Models / project detail), with the Settings
  // modal, search palette, and dialogs hosted as overlays, plus the global
  // keyboard shortcuts (mod+N / mod+P / mod+K, Escape).
  import { onMount } from "svelte";
  import { app } from "$lib/state.svelte";
  import { isModKey } from "$lib/utils";
  import Sidebar from "$lib/components/Sidebar.svelte";
  import ChatHome from "$lib/components/ChatHome.svelte";
  import ProjectsPage from "$lib/components/ProjectsPage.svelte";
  import ModelsPage from "$lib/components/ModelsPage.svelte";
  import SettingsModal from "$lib/components/SettingsModal.svelte";
  import SearchPalette from "$lib/components/SearchPalette.svelte";
  import Dialogs from "$lib/components/Dialogs.svelte";
  import AgentQuestion from "$lib/components/AgentQuestion.svelte";
  import Onboarding from "$lib/components/Onboarding.svelte";
  import ToolConfirm from "$lib/components/ToolConfirm.svelte";

  onMount(async () => {
    await app.load();
    await app.refreshModels();
    // Re-resolve System theme when the OS switches.
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => app.applyAppearance());
  });

  function onKeydown(e: KeyboardEvent) {
    if (isModKey(e)) {
      const key = e.key.toLowerCase();
      if (key === "n") { e.preventDefault(); app.newChat(); }
      else if (key === "p") { e.preventDefault(); app.selection = { kind: "projects" }; }
      else if (key === "k") { e.preventDefault(); app.searchOpen = !app.searchOpen; }
    } else if (e.key === "Escape") {
      if (app.dialog) app.dialog = null;
      else if (app.searchOpen) app.searchOpen = false;
      else if (app.settingsOpen) app.settingsOpen = false;
    }
  }
</script>

<svelte:window onkeydown={onKeydown} />

<div class="root">
  {#if app.sidebarOpen}
    <div class="sidebar-slot">
      <Sidebar />
    </div>
  {/if}

  {#if app.selection.kind === "chat"}
    <ChatHome />
  {:else if app.selection.kind === "projects"}
    <ProjectsPage />
  {:else if app.selection.kind === "project"}
    <ProjectsPage projectId={app.selection.id} />
  {:else if app.selection.kind === "models"}
    <ModelsPage />
  {/if}
</div>

{#if app.settingsOpen}
  <SettingsModal />
{/if}
{#if app.searchOpen}
  <SearchPalette />
{/if}
<Dialogs />
<ToolConfirm />
<AgentQuestion />
<Onboarding />

<style>
  .root {
    display: flex;
    height: 100vh;
    background: var(--bg-primary);
  }
  /* floatingSidebarPanel's insets: top 10, bottom 9, leading 9, trailing 6 */
  .sidebar-slot {
    padding: 10px 6px 9px 9px;
    flex-shrink: 0;
  }
</style>
