<script lang="ts">
  // Port of SidebarView.swift — the floating 240px card: 50px header band
  // with the collapse toggle, mono-14 nav rows with shortcut hints, Pinned,
  // Projects (inline-expandable folders), and date-bucketed chat history
  // with hover ellipsis menus and the background-generating pulse dot.
  import { app } from "$lib/state.svelte";
  import { dateBuckets, modKeyLabel } from "$lib/utils";
  import type { Conversation } from "$lib/types";
  import Icon from "./Icon.svelte";

  let expandedProjects = $state<Set<string>>(new Set());
  let openMenuFor = $state<string | null>(null);

  const navItems = $derived([
    { icon: "new-chat", title: "New Chat", hint: `${modKeyLabel}N`, action: () => app.newChat() },
    {
      icon: "folder-plus", title: "New Projects", hint: `${modKeyLabel}P`,
      active: app.selection.kind === "projects",
      action: () => (app.selection = { kind: "projects" }),
    },
    { icon: "search", title: "Search", hint: `${modKeyLabel}K`, action: () => (app.searchOpen = true) },
    {
      icon: "cube", title: "Models",
      active: app.selection.kind === "models",
      action: () => (app.selection = { kind: "models" }),
    },
    { icon: "gear", title: "Settings", action: () => (app.settingsOpen = true) },
  ]);

  function toggleProject(id: string) {
    const next = new Set(expandedProjects);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    expandedProjects = next;
  }

  function toggleMenu(id: string, event: MouseEvent) {
    event.stopPropagation();
    openMenuFor = openMenuFor === id ? null : id;
  }

  function closeMenus() {
    openMenuFor = null;
  }
</script>

<svelte:window onclick={closeMenus} />

<aside class="sidebar">
  <div class="header" data-tauri-drag-region>
    <button
      class="icon-btn"
      title="Close sidebar"
      onclick={() => (app.sidebarOpen = false)}
    >
      <Icon name="sidebar" size={16} />
    </button>
  </div>

  <div class="scroll">
    <nav>
      {#each navItems as item}
        <button class="nav-row" class:active={item.active} onclick={item.action}>
          <span class="nav-icon"><Icon name={item.icon} size={16} /></span>
          <span class="nav-label">{item.title}</span>
          {#if item.hint}<span class="hint">{item.hint}</span>{/if}
        </button>
      {/each}
    </nav>

    {#if app.pinnedConversations.length}
      <div class="section-head"><span>Pinned</span></div>
      {#each app.pinnedConversations as conversation (conversation.id)}
        {@render chatRow(conversation, true)}
      {/each}
    {/if}

    {#if app.sortedProjects.length}
      <div class="section-head">
        <span>Projects</span>
        <button class="mini-btn" title="New project" onclick={() => (app.dialog = { kind: "newProject" })}>
          <Icon name="plus" size={12} stroke={2.2} />
        </button>
      </div>
      {#each app.sortedProjects as project (project.id)}
        <div class="project-row-wrap">
          <button class="chat-row project" onclick={() => toggleProject(project.id)}>
            <span class="chev" class:open={expandedProjects.has(project.id)}>
              <Icon name="chevron-right" size={10} stroke={2.4} />
            </span>
            <Icon name="folder" size={14} />
            <span class="row-title">{project.name}</span>
          </button>
          <span class="row-menu" class:open={openMenuFor === `p:${project.id}`}>
            <button class="mini-btn" onclick={(e) => toggleMenu(`p:${project.id}`, e)}>
              <Icon name="ellipsis" size={14} />
            </button>
          </span>
          {#if openMenuFor === `p:${project.id}`}
            <div class="menu">
              <button onclick={() => { app.selection = { kind: "project", id: project.id }; closeMenus(); }}>
                <Icon name="folder" size={13} /> Open
              </button>
              <button onclick={() => { app.dialog = { kind: "renameProject", id: project.id }; closeMenus(); }}>
                <Icon name="pencil" size={13} /> Rename
              </button>
              <button class="destructive" onclick={() => { app.dialog = { kind: "deleteProject", id: project.id }; closeMenus(); }}>
                <Icon name="trash" size={13} /> Delete
              </button>
            </div>
          {/if}
          {#if expandedProjects.has(project.id)}
            {#each app.conversationsInProject(project.id) as conversation (conversation.id)}
              <div class="indent">{@render chatRow(conversation, false)}</div>
            {:else}
              <div class="empty-note">No chats yet</div>
            {/each}
          {/if}
        </div>
      {/each}
    {/if}

    {#each dateBuckets(app.unpinnedUnfiledConversations) as bucket, bucketIndex}
      <div class="section-head">
        <span>{bucket.title}</span>
        {#if bucketIndex === 0 && app.unpinnedUnfiledConversations.length > 1}
          <button
            class="mini-btn"
            title="Delete all chats"
            onclick={(e) => toggleMenu("bucket-menu", e)}
          >
            <Icon name="ellipsis" size={13} />
          </button>
        {/if}
      </div>
      {#if bucketIndex === 0 && openMenuFor === "bucket-menu"}
        <div class="menu right">
          <button class="destructive" onclick={() => { app.deleteAllUnfiled(); closeMenus(); }}>
            <Icon name="trash" size={13} /> Delete All
          </button>
        </div>
      {/if}
      {#each bucket.conversations as conversation (conversation.id)}
        {@render chatRow(conversation, true)}
      {/each}
    {/each}
  </div>
</aside>

{#snippet chatRow(conversation: Conversation, showsPin: boolean)}
  <div class="chat-row-wrap">
    <button
      class="chat-row"
      class:active={app.currentId === conversation.id && app.selection.kind === "chat"}
      onclick={() => app.selectConversation(conversation.id)}
    >
      <span class="row-title">{conversation.title}</span>
      {#if app.isGeneratingInBackground(conversation.id)}
        <span class="gen-dot" title="Still generating a reply"></span>
      {:else if conversation.hasUnread}
        <span class="unread-dot"></span>
      {/if}
    </button>
    <span class="row-menu" class:open={openMenuFor === conversation.id}>
      <button class="mini-btn" onclick={(e) => toggleMenu(conversation.id, e)}>
        <Icon name="ellipsis" size={14} />
      </button>
    </span>
    {#if openMenuFor === conversation.id}
      <div class="menu">
        {#if showsPin}
          <button onclick={() => { app.togglePinned(conversation.id); closeMenus(); }}>
            <Icon name="pin" size={13} /> {conversation.isPinned ? "Unpin" : "Pin"}
          </button>
        {/if}
        <button onclick={() => { app.dialog = { kind: "renameChat", id: conversation.id }; closeMenus(); }}>
          <Icon name="pencil" size={13} /> Rename
        </button>
        <button class="destructive" onclick={() => { app.dialog = { kind: "deleteChat", id: conversation.id }; closeMenus(); }}>
          <Icon name="trash" size={13} /> Delete
        </button>
      </div>
    {/if}
  </div>
{/snippet}

<style>
  .sidebar {
    width: 240px;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: var(--bg-sidebar);
    border: 1px solid var(--border-subtle);
    border-radius: 16px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.18);
    overflow: hidden;
  }
  .header {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    height: 50px;
    padding: 0 10px;
    flex-shrink: 0;
  }
  .icon-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    border: none;
    background: transparent;
    border-radius: 8px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .icon-btn:hover {
    background: var(--bg-hover);
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
    padding: 0 8px 12px;
  }
  nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-bottom: 6px;
  }
  .nav-row {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 7px 10px;
    border: none;
    background: transparent;
    border-radius: 9px;
    cursor: pointer;
    color: var(--text-primary);
    text-align: left;
    width: 100%;
  }
  .nav-row:hover {
    background: var(--bg-hover);
  }
  .nav-row.active {
    background: var(--bg-selected);
  }
  .nav-icon {
    display: flex;
    width: 20px;
    justify-content: center;
    color: var(--text-primary);
    opacity: 0.85;
  }
  .nav-label {
    font-family: var(--font-mono);
    font-size: 14px;
    flex: 1;
  }
  .hint {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-tertiary);
    padding: 12px 10px 4px;
  }
  .mini-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border: none;
    background: transparent;
    border-radius: 5px;
    color: var(--text-tertiary);
    cursor: pointer;
  }
  .mini-btn:hover {
    background: var(--bg-hover);
    color: var(--text-secondary);
  }
  .chat-row-wrap,
  .project-row-wrap {
    position: relative;
  }
  .chat-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    text-align: left;
    border: none;
    background: transparent;
    border-radius: 9px;
    padding: 7px 10px;
    cursor: pointer;
    color: var(--text-primary);
  }
  .chat-row:hover {
    background: var(--bg-hover);
  }
  .chat-row.active {
    background: var(--bg-selected);
  }
  .chat-row.project {
    color: var(--text-primary);
  }
  .chev {
    display: inline-flex;
    color: var(--text-tertiary);
    transition: transform 0.15s ease;
  }
  .chev.open {
    transform: rotate(90deg);
  }
  .row-title {
    font-family: var(--font-mono);
    font-size: 14px;
    flex: 1;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-menu {
    position: absolute;
    right: 8px;
    top: 50%;
    transform: translateY(-50%);
    opacity: 0;
    display: inline-flex;
  }
  .chat-row-wrap:hover .row-menu,
  .project-row-wrap:hover .row-menu,
  .row-menu.open {
    opacity: 1;
  }
  .chat-row-wrap .row-title,
  .project-row-wrap .row-title {
    padding-right: 18px;
  }
  .gen-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-secondary);
    animation: pulse 1.4s ease-in-out infinite;
    flex-shrink: 0;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.3; }
  }
  .unread-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--text-primary);
    flex-shrink: 0;
  }
  .indent {
    padding-left: 20px;
  }
  .empty-note {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-tertiary);
    padding: 5px 10px 5px 38px;
  }
  .menu {
    position: absolute;
    right: 6px;
    top: 32px;
    z-index: 40;
    min-width: 150px;
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    box-shadow: 0 8px 24px var(--shadow);
    padding: 4px;
    display: flex;
    flex-direction: column;
  }
  .menu.right {
    top: auto;
  }
  .menu button {
    display: flex;
    align-items: center;
    gap: 8px;
    border: none;
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-sans);
    font-size: 13px;
    padding: 6px 10px;
    border-radius: 7px;
    cursor: pointer;
    text-align: left;
  }
  .menu button:hover {
    background: var(--bg-hover);
  }
  .menu button.destructive {
    color: var(--destructive);
  }
</style>
