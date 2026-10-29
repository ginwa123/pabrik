<script setup lang="ts">
defineProps<{
  effectiveSelection: string
  showCurrentFolderHint: boolean
  canSelect: boolean
  selectLabel: string
}>()

const emit = defineEmits<{
  cancel: []
  select: []
}>()
</script>

<template>
  <div
    class="px-5 py-3 flex items-center gap-3 shrink-0"
    style="
      border-top: 1px solid var(--color-border);
      background-color: var(--semantic-sidebar-bg);
    "
  >
    <div class="flex-1 min-w-0 flex items-center gap-2">
      <span
        class="text-dense shrink-0"
        style="color: var(--semantic-text-dim)"
        >Selected:</span
      >
      <span
        class="text-dense font-mono truncate"
        style="
          color: var(--semantic-text);
          direction: rtl;
          text-align: left;
        "
        :title="effectiveSelection || '(none)'"
        data-testid="file-picker-selected-path"
        >{{ effectiveSelection || '(none)' }}</span
      >
      <!--
        NEW (plan: 2026-08-13-folder-picker-select-button-current-folder.md).
        Hint shown when the Select button is enabled via the fallback
        path (currentPath, not selectedPath). Tells the user "the
        button is on because you're sitting on this folder, not
        because you clicked it". Hidden when selectedPath is set
        (explicit click is more specific) or in file mode.
      -->
      <span
        v-if="showCurrentFolderHint"
        class="text-micro shrink-0"
        style="color: var(--semantic-text-dim)"
        data-testid="file-picker-selected-hint"
        >← current folder</span
      >
    </div>

    <slot name="footer" />

    <button
      @click="emit('cancel')"
      data-testid="file-picker-cancel"
      class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text-muted);
      "
    >
      Cancel
    </button>
    <button
      @click="emit('select')"
      :disabled="!canSelect"
      data-testid="file-picker-select"
      class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
      style="
        background: linear-gradient(
          135deg,
          var(--color-violet),
          var(--color-blue)
        );
        color: var(--color-bg);
      "
    >
      {{ selectLabel }}
    </button>
  </div>
</template>
