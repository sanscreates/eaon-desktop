<script lang="ts">
  // Port of Dialogs.swift — the centered radius-20 confirmation/input cards
  // over the dimmed backdrop, driven by app.dialog. Delete flows verify
  // outcomes (a model deletion that didn't free disk says so, Mac parity).
  import { app } from "$lib/state.svelte";
  import { formatBytes } from "$lib/utils";
  import Icon from "./Icon.svelte";

  let inputValue = $state("");
  let deleteFailure = $state<string | null>(null);
  let deleting = $state(false);

  const dialog = $derived(app.dialog);

  $effect(() => {
    // Seed the input when a rename dialog opens.
    const current = app.dialog;
    deleteFailure = null;
    if (!current) {
      inputValue = "";
      return;
    }
    if (current.kind === "renameChat") {
      inputValue = app.conversations.find((c) => c.id === current.id)?.title ?? "";
    } else if (current.kind === "renameProject") {
      inputValue = app.projects.find((p) => p.id === current.id)?.name ?? "";
    } else if (current.kind === "newProject") {
      inputValue = "";
    }
  });

  function close() {
    app.dialog = null;
  }

  function confirm() {
    const current = dialog;
    if (!current) return;
    if (current.kind === "deleteChat") {
      app.deleteConversation(current.id);
      close();
    } else if (current.kind === "renameChat") {
      app.renameConversation(current.id, inputValue);
      close();
    } else if (current.kind === "newProject") {
      const project = app.createProject(inputValue);
      app.selection = { kind: "project", id: project.id };
      close();
    } else if (current.kind === "renameProject") {
      app.renameProject(current.id, inputValue);
      close();
    } else if (current.kind === "deleteProject") {
      app.deleteProject(current.id);
      close();
    } else if (current.kind === "deleteModel") {
      deleting = true;
      app.deleteModel(current.name).then((failure) => {
        deleting = false;
        if (failure) deleteFailure = failure;
        else close();
      });
    }
  }

  const meta = $derived.by(() => {
    const current = dialog;
    if (!current) return null;
    switch (current.kind) {
      case "deleteChat": {
        const conversation = app.conversations.find((c) => c.id === current.id);
        return {
          title: "Delete chat?",
          body: `"${conversation?.title ?? "This chat"}" will be permanently deleted.`,
          confirm: "Delete", destructive: true, input: false,
        };
      }
      case "renameChat":
        return { title: "Rename chat", body: null, confirm: "Rename", destructive: false, input: true };
      case "newProject":
        return { title: "New project", body: "Give the folder a name.", confirm: "Create", destructive: false, input: true };
      case "renameProject":
        return { title: "Rename project", body: null, confirm: "Rename", destructive: false, input: true };
      case "deleteProject": {
        const project = app.projects.find((p) => p.id === current.id);
        return {
          title: "Delete project?",
          body: `"${project?.name ?? "This project"}" will be deleted. Its chats are kept — just un-grouped.`,
          confirm: "Delete", destructive: true, input: false,
        };
      }
      case "deleteModel": {
        const model = app.ollamaModels.find((m) => m.name === current.name);
        return {
          title: "Delete this model?",
          body: `${current.name} will be removed from this PC${model ? ` (frees ${formatBytes(model.sizeBytes)})` : ""}. You can download it again anytime.`,
          confirm: "Delete", destructive: true, input: false,
        };
      }
    }
  });
</script>

{#if dialog && meta}
  <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
  <div class="overlay" onclick={close}>
    <div class="card" onclick={(e) => e.stopPropagation()}>
      <div class="title">
        {#if meta.destructive}<span class="warn"><Icon name="warning" size={16} /></span>{/if}
        {meta.title}
      </div>
      {#if meta.body}<p class="body">{meta.body}</p>{/if}
      {#if meta.input}
        <!-- svelte-ignore a11y_autofocus -->
        <input
          autofocus
          bind:value={inputValue}
          onkeydown={(e) => { if (e.key === "Enter") confirm(); if (e.key === "Escape") close(); }}
        />
      {/if}
      {#if deleteFailure}
        <p class="failure">{deleteFailure}</p>
      {/if}
      <div class="actions">
        <button class="btn secondary" onclick={close}>Cancel</button>
        <button
          class="btn"
          class:destructive={meta.destructive}
          class:primary={!meta.destructive}
          disabled={deleting || (meta.input && !inputValue.trim())}
          onclick={confirm}
        >
          {deleting ? "…" : meta.confirm}
        </button>
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
    z-index: 110;
  }
  .card {
    width: 440px;
    max-width: calc(100vw - 48px);
    background: var(--bg-popover);
    border: 1px solid var(--border-subtle);
    border-radius: 20px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.3);
    padding: 24px;
    animation: pop 0.18s ease-out;
  }
  @keyframes pop {
    from { transform: scale(0.94); opacity: 0; }
    to { transform: scale(1); opacity: 1; }
  }
  .title {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: var(--font-mono);
    font-size: 18px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 14px;
  }
  .warn {
    color: #e8a838;
    display: inline-flex;
  }
  .body {
    font-family: var(--font-sans);
    font-size: 14px;
    color: var(--text-secondary);
    line-height: 1.55;
    margin: 0 0 20px;
  }
  input {
    width: 100%;
    background: var(--bg-input-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    padding: 10px 14px;
    font-family: var(--font-sans);
    font-size: 14px;
    outline: none;
    margin-bottom: 20px;
  }
  input:focus {
    border-color: var(--border-medium);
  }
  .failure {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--destructive);
    margin: 0 0 16px;
    line-height: 1.5;
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
  }
  .btn {
    border: none;
    border-radius: 999px;
    font-family: var(--font-mono);
    font-size: 14px;
    font-weight: 500;
    padding: 0 18px;
    height: 38px;
    cursor: pointer;
  }
  .btn.secondary {
    background: transparent;
    border: 1px solid var(--border-medium);
    color: var(--text-primary);
  }
  .btn.secondary:hover {
    background: var(--bg-hover);
  }
  .btn.primary {
    background: var(--text-primary);
    color: var(--bg-primary);
  }
  .btn.destructive {
    background: var(--destructive);
    color: #fff;
  }
  .btn:disabled {
    opacity: 0.4;
    cursor: default;
  }
</style>
