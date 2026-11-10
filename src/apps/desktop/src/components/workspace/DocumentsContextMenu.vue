<!--
  DocumentsContextMenu — the right-click action menu for a document row in the
  sidebar's Documents section.

  Teleported to body so the sidebar's own scroll container can never clip it.
  Visibility is `v-if` on the host's menu state; the host owns the position and
  the selection, this component only reports intent.

  The export row's label carries the count, because the whole point of the
  multi-select is that the user can see how many files they are about to get.
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue'

const props = withDefaults(
  defineProps<{
    x: number
    y: number
    /** How many documents the export row will write. */
    selectedCount?: number
    /** Total documents in the section, for the "export all" row. */
    totalCount?: number
    /** True while an export is in flight — the rows are disabled. */
    busy?: boolean
  }>(),
  { selectedCount: 0, totalCount: 0, busy: false },
)

const emit = defineEmits<{
  exportSelected: []
  exportAll: []
  selectAll: []
  clearSelection: []
}>()

const rootRef = ref<HTMLElement | null>(null)

const exportLabel = computed(() =>
  props.selectedCount === 1 ? 'Export document' : `Export ${props.selectedCount} documents`,
)

const canExportAll = computed(() => props.totalCount > 0)

/** Focus the first row so the menu is usable from the keyboard the moment it opens. The host
 * mounts a fresh menu per open, so mount is the only moment this has to run. */
onMounted(async () => {
  await nextTick()
  rootRef.value?.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
})

const rows = (): HTMLElement[] =>
  Array.from(rootRef.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])

const onKeydown = (event: KeyboardEvent) => {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
  event.preventDefault()
  const items = rows()
  if (items.length === 0) return
  const at = items.indexOf(document.activeElement as HTMLElement)
  const delta = event.key === 'ArrowDown' ? 1 : -1
  items[(at + delta + items.length) % items.length]?.focus()
}

const focusRow = (event: MouseEvent) => {
  ;(event.currentTarget as HTMLElement | null)?.focus()
}
</script>

<template>
  <Teleport to="body">
    <div
      ref="rootRef"
      data-context-menu
      data-testid="documents-context-menu"
      role="menu"
      aria-label="Document actions"
      class="fixed z-[60] py-1 text-dense rounded-lg shadow-lg min-w-[210px] outline-none"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
      @contextmenu.prevent
      @keydown="onKeydown"
    >
      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-export"
        class="menu-row"
        :disabled="busy || selectedCount === 0"
        @click="emit('exportSelected')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 3v12m0 0l-4-4m4 4l4-4M4 17v2a2 2 0 002 2h12a2 2 0 002-2v-2"
            />
          </svg>
        </span>
        <span class="menu-lb">{{ exportLabel }}</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-export-all"
        class="menu-row"
        :disabled="busy || !canExportAll"
        @click="emit('exportAll')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4 7V5a2 2 0 012-2h2M4 17v2a2 2 0 002 2h2m8-18h2a2 2 0 012 2v2m-4 14h2a2 2 0 002-2v-2M12 8v8m0 0l-3-3m3 3l3-3"
            />
          </svg>
        </span>
        <span class="menu-lb">Export all documents</span>
      </button>

      <div class="menu-sep" role="separator" />

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-select-all"
        class="menu-row"
        :disabled="!canExportAll"
        @click="emit('selectAll')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#10003;</span>
        <span class="menu-lb">Select all</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-clear"
        class="menu-row"
        :disabled="selectedCount === 0"
        @click="emit('clearSelection')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#10005;</span>
        <span class="menu-lb">Clear selection</span>
      </button>
    </div>
  </Teleport>
</template>

<style scoped>
.menu-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.3rem 0.75rem;
  border: 0;
  background: transparent;
  cursor: pointer;
  text-align: left;
  font-family: inherit;
  font-size: var(--text-dense);
  color: inherit;
}

.menu-row:hover:not(:disabled),
.menu-row:focus-visible:not(:disabled) {
  background: var(--semantic-active-bg);
  outline: none;
}

.menu-row:disabled {
  opacity: 0.45;
  cursor: default;
}

.menu-ic {
  width: 0.875rem;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  opacity: 0.75;
}

.menu-ic :deep(svg) {
  width: 0.875rem;
  height: 0.875rem;
}

.menu-lb {
  flex: 1;
  min-width: 0;
}

.menu-sep {
  height: 1px;
  margin: 0.25rem 0;
  background: var(--color-border);
}
</style>
