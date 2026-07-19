<script lang="ts">
  // The .switch toggle style — always green when on, independent of the
  // user's accent color (matches the Mac app's fixed toggle tint).
  let {
    checked = $bindable(false),
    onchange = () => {},
  }: { checked?: boolean; onchange?: (value: boolean) => void } = $props();
</script>

<button
  class="switch"
  class:on={checked}
  role="switch"
  aria-checked={checked}
  onclick={() => {
    checked = !checked;
    onchange(checked);
  }}
>
  <span class="knob"></span>
</button>

<style>
  .switch {
    width: 38px;
    height: 22px;
    border-radius: 999px;
    border: none;
    background: var(--bg-chip-secondary);
    position: relative;
    cursor: pointer;
    transition: background 0.18s ease;
    flex-shrink: 0;
  }
  .switch.on {
    background: #34c759;
  }
  .knob {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
    transition: transform 0.18s ease;
  }
  .switch.on .knob {
    transform: translateX(16px);
  }
</style>
