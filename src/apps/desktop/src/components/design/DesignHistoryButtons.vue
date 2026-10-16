<!--
  DesignHistoryButtons — toolbar undo/redo buttons.

  Renders two buttons with disabled states + tooltips that show the
  next undo/redo entry's label. Click handlers delegate to the
  `useDesignHistory` composable (no local state).

  Test contract:
    data-testid="design-undo-button" on the undo button
    data-testid="design-redo-button" on the redo button
    Title attribute format: "Undo: <label>" / "Redo: <label>"
-->
<script setup lang="ts">
import { computed } from 'vue'
import { useDesignHistory } from '../../composables/useDesignHistory'

const props = defineProps<{
  workspaceId: string
  itemId: string
  pageId: string
}>()

// Keep the pageId prop reactive by deriving a computed. We don't need the workspaceId/itemId here
// directly (the composable reads them from the workspaces store), but they're required props so any
// future direct use is ergonomic.
const pageIdComputed = computed(() => props.pageId)
const history = useDesignHistory(pageIdComputed)

function handleUndo(): void {
  void history.undo()
}

function handleRedo(): void {
  void history.redo()
}
</script>

<template>
  <div class="design-history-buttons flex items-center gap-1" data-testid="design-history-buttons">
    <button
      type="button"
      class="px-2 py-1 rounded text-dense flex items-center gap-1"
      style="background: var(--color-border); color: var(--semantic-text);"
      :disabled="!history.canUndo.value"
      :title="history.nextUndoLabel.value ? `Undo: ${history.nextUndoLabel.value}` : 'Undo'"
      data-testid="design-undo-button"
      @click="handleUndo"
    >
      <span aria-hidden="true">↶</span>
      <span>Undo</span>
    </button>
    <button
      type="button"
      class="px-2 py-1 rounded text-dense flex items-center gap-1"
      style="background: var(--color-border); color: var(--semantic-text);"
      :disabled="!history.canRedo.value"
      :title="history.nextRedoLabel.value ? `Redo: ${history.nextRedoLabel.value}` : 'Redo'"
      data-testid="design-redo-button"
      @click="handleRedo"
    >
      <span aria-hidden="true">↷</span>
      <span>Redo</span>
    </button>
  </div>
</template>
