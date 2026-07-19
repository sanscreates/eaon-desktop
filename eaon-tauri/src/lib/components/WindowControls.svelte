<script lang="ts">
  // Frameless-window controls. The Mac app hides its title bar and lets the
  // native traffic lights sit over the sidebar card; on Windows the same
  // seamless look means decorations:false plus our own min/max/close,
  // top-right per Windows convention.
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import Icon from "./Icon.svelte";

  // Resolved lazily so a plain-browser preview (no Tauri runtime) still
  // renders the rest of the app instead of dying at component init.
  const hasTauri = "__TAURI_INTERNALS__" in window;
  const win = () => getCurrentWindow();
</script>

{#if hasTauri}
  <div class="controls">
    <button class="wc" title="Minimize" onclick={() => win().minimize()}>
      <Icon name="window-min" size={13} stroke={1.6} />
    </button>
    <button class="wc" title="Maximize" onclick={() => win().toggleMaximize()}>
      <Icon name="window-max" size={11} stroke={1.6} />
    </button>
    <button class="wc close" title="Close" onclick={() => win().close()}>
      <Icon name="xmark" size={13} stroke={1.6} />
    </button>
  </div>
{/if}

<style>
  .controls {
    display: flex;
    align-items: center;
    gap: 2px;
  }
  .wc {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 28px;
    border: none;
    background: transparent;
    border-radius: 7px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .wc:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
  .wc.close:hover {
    background: var(--destructive);
    color: #fff;
  }
</style>
