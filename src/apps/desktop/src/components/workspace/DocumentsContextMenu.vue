<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue'

const props = withDefaults(
  defineProps<{
    x: number
    y: number
    title?: string
    selectedCount?: number
    totalCount?: number
    singleSelected?: boolean
    busy?: boolean
    /** A folder row opens the same menu with only the row edits it can use. */
    kind?: 'document' | 'folder'
  }>(),
  {
    title: '',
    selectedCount: 0,
    totalCount: 0,
    singleSelected: false,
    busy: false,
    kind: 'document',
  },
)

const emit = defineEmits<{
  open: []
  rename: []
  changeIcon: []
  duplicate: []
  copyLink: []
  remove: []
  exportSelected: []
  exportAll: []
  selectAll: []
  clearSelection: []
}>()

const rootRef = ref<HTMLElement | null>(null)

const exportLabel = computed(() =>
  props.selectedCount === 1 ? 'Export document' : `Export ${props.selectedCount} documents`,
)

const duplicateLabel = computed(() =>
  props.selectedCount === 1 ? 'Duplicate' : `Duplicate ${props.selectedCount} documents`,
)

const deleteLabel = computed(() =>
  props.selectedCount === 1 ? 'Delete' : `Delete ${props.selectedCount} documents`,
)

const canExportAll = computed(() => props.totalCount > 0)

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
      <div
        v-if="title"
        class="px-3 pt-1 pb-1.5 mb-1 border-b truncate max-w-[240px]"
        style="border-color: var(--color-border); color: var(--semantic-text-dim)"
        data-testid="documents-context-menu-title"
        :title="title"
      >
        {{ title }}
      </div>

      <button
        v-if="kind === 'document'"
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-open"
        class="menu-row"
        :disabled="busy || !singleSelected"
        @click="emit('open')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M14 3h7v7m0-7L10 14M19 14v5a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2h5"
            />
          </svg>
        </span>
        <span class="menu-lb">Open</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-rename"
        class="menu-row"
        :disabled="busy || !singleSelected"
        @click="emit('rename')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
            />
          </svg>
        </span>
        <span class="menu-lb">Rename</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-change-icon"
        class="menu-row"
        :disabled="busy || !singleSelected"
        @click="emit('changeIcon')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"
            />
          </svg>
        </span>
        <span class="menu-lb">Change icon…</span>
      </button>

      <button
        v-if="kind === 'document'"
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-duplicate"
        class="menu-row"
        :disabled="busy || selectedCount === 0"
        @click="emit('duplicate')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M8 8V5a2 2 0 012-2h9a2 2 0 012 2v9a2 2 0 01-2 2h-3M5 8h9a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2v-9a2 2 0 012-2z"
            />
          </svg>
        </span>
        <span class="menu-lb">{{ duplicateLabel }}</span>
      </button>

      <button
        v-if="kind === 'document'"
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-copy-link"
        class="menu-row"
        :disabled="busy || !singleSelected"
        @click="emit('copyLink')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M10 13a5 5 0 007.07 0l2.83-2.83a5 5 0 00-7.07-7.07L11 4.93M14 11a5 5 0 00-7.07 0L4.1 13.83a5 5 0 007.07 7.07L13 19.07"
            />
          </svg>
        </span>
        <span class="menu-lb">Copy link</span>
      </button>

      <div class="menu-sep" role="separator" />

      <button
        v-if="kind === 'document'"
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
        v-if="kind === 'document'"
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
        v-if="kind === 'document'"
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
        v-if="kind === 'document'"
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

      <div class="menu-sep" role="separator" />

      <button
        type="button"
        role="menuitem"
        data-testid="documents-context-menu-delete"
        class="menu-row menu-row--danger"
        :disabled="busy || selectedCount === 0"
        @click="emit('remove')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4 7h16M10 11v6m4-6v6M6 7l1 12a2 2 0 002 2h6a2 2 0 002-2l1-12M9 7V5a2 2 0 012-2h2a2 2 0 012 2v2"
            />
          </svg>
        </span>
        <span class="menu-lb">{{ deleteLabel }}</span>
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

.menu-row--danger {
  color: var(--color-red);
}

.menu-row--danger:hover:not(:disabled),
.menu-row--danger:focus-visible:not(:disabled) {
  background: var(--tint-error);
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
