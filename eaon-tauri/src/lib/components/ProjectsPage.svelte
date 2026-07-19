<script lang="ts">
  // Port of ProjectsView.swift + ProjectDetailScreen — the folder grid
  // (adaptive 180–220px cards) with empty state, and the per-project chat
  // list with its "New chat in <project>" row.
  import { app } from "$lib/state.svelte";
  import Icon from "./Icon.svelte";
  import WindowControls from "./WindowControls.svelte";

  let { projectId = null }: { projectId?: string | null } = $props();

  const project = $derived(projectId ? app.projects.find((p) => p.id === projectId) ?? null : null);
  const chats = $derived(project ? app.conversationsInProject(project.id) : []);
</script>

<div class="page">
  {#if project}
    <div class="bar" data-tauri-drag-region>
      <button class="icon-btn" onclick={() => (app.selection = { kind: "projects" })}>
        <Icon name="chevron-left" size={14} stroke={2.2} />
      </button>
      <span class="bar-title">{project.name}</span>
      <span class="spacer" data-tauri-drag-region></span>
      <button class="icon-btn" title="Rename" onclick={() => (app.dialog = { kind: "renameProject", id: project.id })}>
        <Icon name="pencil" size={14} />
      </button>
      <button class="icon-btn" title="Delete" onclick={() => (app.dialog = { kind: "deleteProject", id: project.id })}>
        <Icon name="trash" size={14} />
      </button>
      <WindowControls />
    </div>
    <div class="divider"></div>
    <div class="scroll">
      <div class="detail">
        <button class="new-chat-row" onclick={() => app.newChat(project.id)}>
          <Icon name="new-chat" size={14} />
          New chat in {project.name}
        </button>
        {#each chats as conversation (conversation.id)}
          <button
            class="chat-row"
            class:active={app.currentId === conversation.id}
            onclick={() => app.selectConversation(conversation.id)}
          >
            <Icon name="message" size={13} />
            <span class="chat-title">{conversation.title}</span>
          </button>
        {:else}
          <div class="none">No chats in this project yet.</div>
        {/each}
      </div>
    </div>
  {:else}
    <div class="bar" data-tauri-drag-region>
      <span class="bar-title">Projects</span>
      <span class="spacer" data-tauri-drag-region></span>
      <button class="new-btn" onclick={() => (app.dialog = { kind: "newProject" })}>
        <Icon name="plus" size={12} stroke={2.4} /> New project
      </button>
      <WindowControls />
    </div>
    <div class="divider"></div>
    {#if !app.sortedProjects.length}
      <div class="empty">
        <span class="empty-circle"><Icon name="folder" size={28} /></span>
        <h2>Projects</h2>
        <p>Group related chats into a folder.</p>
        <button class="cta" onclick={() => (app.dialog = { kind: "newProject" })}>
          <Icon name="plus" size={12} stroke={2.4} /> New project
        </button>
      </div>
    {:else}
      <div class="scroll">
        <div class="grid">
          {#each app.sortedProjects as project (project.id)}
            <button class="card" onclick={() => (app.selection = { kind: "project", id: project.id })}>
              <span class="folder"><Icon name="folder-fill" size={22} /></span>
              <span class="card-name">{project.name}</span>
              <span class="card-count">
                {app.conversationsInProject(project.id).length === 1
                  ? "1 chat"
                  : `${app.conversationsInProject(project.id).length} chats`}
              </span>
            </button>
          {/each}
        </div>
      </div>
    {/if}
  {/if}
</div>

<style>
  .page {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--bg-primary);
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 50px;
    padding: 10px 14px 0;
    flex-shrink: 0;
  }
  .bar-title {
    font-family: var(--font-sans);
    font-size: 15px;
    font-weight: 600;
  }
  .spacer {
    flex: 1;
    height: 100%;
  }
  .icon-btn {
    display: flex;
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
  .icon-btn:hover {
    background: var(--bg-hover);
  }
  .new-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--border-medium);
    border-radius: 999px;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 500;
    padding: 7px 12px;
    cursor: pointer;
  }
  .new-btn:hover {
    background: var(--bg-hover);
  }
  .divider {
    height: 1px;
    background: var(--border-subtle);
    margin-top: 10px;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 220px));
    gap: 12px;
    padding: 20px;
  }
  .card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 10px;
    padding: 14px;
    border: 1px solid var(--border-subtle);
    border-radius: 12px;
    background: var(--bg-subtle);
    cursor: pointer;
    text-align: left;
  }
  .card:hover {
    background: var(--bg-hover);
  }
  .folder {
    color: var(--text-secondary);
  }
  .card-name {
    font-family: var(--font-sans);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .card-count {
    font-family: var(--font-sans);
    font-size: 12px;
    color: var(--text-tertiary);
  }
  .empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding-bottom: 8vh;
  }
  .empty-circle {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 72px;
    height: 72px;
    border-radius: 50%;
    background: var(--bg-subtle);
    color: var(--text-secondary);
  }
  .empty h2 {
    font-family: var(--font-sans);
    font-size: 22px;
    font-weight: 600;
    margin: 0;
  }
  .empty p {
    font-family: var(--font-sans);
    font-size: 14px;
    color: var(--text-secondary);
    margin: 0;
  }
  .cta {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: none;
    border-radius: 999px;
    background: var(--text-primary);
    color: var(--bg-primary);
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 600;
    padding: 9px 16px;
    cursor: pointer;
    margin-top: 4px;
  }
  .detail {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-width: 720px;
  }
  .new-chat-row {
    display: flex;
    align-items: center;
    gap: 10px;
    border: none;
    border-radius: 9px;
    background: var(--bg-subtle);
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 14px;
    font-weight: 500;
    padding: 9px 12px;
    cursor: pointer;
    text-align: left;
    margin-bottom: 8px;
  }
  .chat-row {
    display: flex;
    align-items: center;
    gap: 8px;
    border: none;
    border-radius: 9px;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 14px;
    padding: 8px 12px;
    cursor: pointer;
    text-align: left;
  }
  .chat-row:hover {
    background: var(--bg-hover);
  }
  .chat-row.active {
    background: var(--bg-selected);
  }
  .chat-row :global(svg) {
    color: var(--text-secondary);
  }
  .chat-title {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .none {
    font-family: var(--font-sans);
    font-size: 13px;
    color: var(--text-tertiary);
    text-align: center;
    padding-top: 20px;
  }
</style>
