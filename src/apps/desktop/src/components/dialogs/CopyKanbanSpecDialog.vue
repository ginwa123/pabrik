<!--
  CopyKanbanSpecDialog — modal for copying one kanban's column
  spec (names + descriptions, preserving order) into a target
  kanban. Mounted from the ⚙ Settings dialog's footer button.

  Layout (top → bottom):
    1. Header — "Copy spec from…" title + close.
    2. Custom source picker — a click-to-open list of the
       workspace's other kanbans (the active target is filtered
       out). A custom list (not <select>) is used because the
       browser's native <select> rendering doesn't pick up the
       app's dark-theme tokens, resulting in inconsistent /
       mis-styled pickers across platforms.
    3. Mode radio — "Replace existing columns" (destructive) or
       "Append at the end" (additive). Replace is the default.
    4. Source preview — small inline list of the source's
       columns, so the user knows exactly what's about to be
       copied.
    5. Confirm button — fires the copy, then closes.

  Public API:
    props:
      show        boolean
      workspaceId string
      targetItemId string — the kanban the user wants to copy INTO
                             (filtered out of the source picker)
    emits:
      close       []
      copy        [sourceItemId: string, mode: 'replace' | 'append']

  The dialog is purely presentational — the host (AppLayout)
  delegates to workspacesStore.copyKanbanSpecFrom on each emit.

    (Chunk 4, Task 4.1)
-->
<script setup lang="ts">
import { ref, computed, nextTick, onBeforeUnmount, onMounted, onUpdated } from 'vue'
import { useWorkspacesStore, type WorkspaceItem } from '../../stores/workspaces'
import * as api from '../../api'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  show: boolean
  workspaceId: string
  targetItemId: string
}>()

const emit = defineEmits<{
  close: []
  copy: [sourceItemId: string, mode: 'replace' | 'append']
}>()

const workspacesStore = useWorkspacesStore()

// ─── State ────────────────────────────────────────────────────────────
const sourceItemId = ref<string>('')
const mode = ref<'replace' | 'append'>('replace')
const sourceDropdownOpen = ref<boolean>(false)
const sourceColumns = ref<Array<{ id: string; name: string; description: string }>>([])
const sourceColumnsLoading = ref<boolean>(false)

// ─── Picker data ──────────────────────────────────────────────────────
// All kanbans in the active workspace EXCEPT the target.
const availableSources = computed<WorkspaceItem[]>(() => {
  return workspacesStore.workspaces
    .flatMap((ws) => (ws.id === props.workspaceId ? ws.items : []))
    .filter(
      (item) =>
        item.item_type === 'kanban' && item.id !== props.targetItemId,
    )
    .sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
})

// Currently selected source (for the trigger label and preview).
const selectedSource = computed<WorkspaceItem | null>(() => {
  if (!sourceItemId.value) return null
  return (
    availableSources.value.find((it) => it.id === sourceItemId.value) ?? null
  )
})

const targetName = computed<string>(() => {
  const t = workspacesStore.workspaces
    .flatMap((ws) => (ws.id === props.workspaceId ? ws.items : []))
    .find((it) => it.id === props.targetItemId)
  return t?.name ?? 'this kanban'
})

// ─── Source columns preview ───────────────────────────────────────────
async function loadSourceColumns(itemId: string) {
  if (!itemId || !props.workspaceId) {
    sourceColumns.value = []
    return
  }
  sourceColumnsLoading.value = true
  try {
    const result = await api.listKanbanColumns(props.workspaceId, itemId)
    sourceColumns.value = result.columns.map((c) => ({
      id: c.id,
      name: c.name,
      description: c.description ?? '',
    }))
  } catch {
    sourceColumns.value = []
  } finally {
    sourceColumnsLoading.value = false
  }
}

// ─── Handlers ─────────────────────────────────────────────────────────
const handleCopy = () => {
  if (!sourceItemId.value) return
  emit('copy', sourceItemId.value, mode.value)
  handleClose()
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    if (sourceDropdownOpen.value) {
      sourceDropdownOpen.value = false
    } else {
      handleClose()
    }
  }
}

const selectSource = (id: string) => {
  sourceItemId.value = id
  sourceDropdownOpen.value = false
  void loadSourceColumns(id)
}

const onDocumentClick = (e: MouseEvent) => {
  // Close the dropdown on outside click. We check via composedPath
  // because the dropdown is teleported (well, rendered inline here
  // but with absolute positioning over the page).
  const target = e.target as HTMLElement | null
  if (!target) return
  if (!target.closest('[data-copy-kanban-spec-picker]')) {
    sourceDropdownOpen.value = false
  }
}

// ─── Lifecycle ──────────────────────────────────────────────────────── Reset + preselect on every
// open (open-sync guard below) and detach the outside-click listener after close (Transition
// after-leave). onBeforeUnmount below remains as the unmount safety net.
const handleOpen = async () => {
  sourceItemId.value = ''
  mode.value = 'replace'
  sourceColumns.value = []
  const first = availableSources.value[0]
  if (first) {
    sourceItemId.value = first.id
    void loadSourceColumns(first.id)
  }
  sourceDropdownOpen.value = false
  await nextTick()
  document.addEventListener('click', onDocumentClick)
}
const handleCloseLeave = () => {
  document.removeEventListener('click', onDocumentClick)
}

onBeforeUnmount(() => {
  document.removeEventListener('click', onDocumentClick)
})

// Open-reset without watch(): seed on mount (initial show=true) and on closed->open updates. A
// Transition before-enter hook cannot do this — it never fires on initial mount (no `appear`) and
// VTU stubs Transition, so specs that mount then setProps(show=true) would see empty fields.
const wasShown = ref(props.show)
onMounted(() => {
  if (props.show) void handleOpen()
})
onUpdated(() => {
  if (props.show && !wasShown.value) void handleOpen()
  wasShown.value = props.show
})
</script>

<template>
  <Teleport to="body">
    <Transition name="copy-kanban-spec-modal" @after-leave="handleCloseLeave">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="copy-kanban-spec-title"
        data-testid="copy-kanban-spec-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-lg mx-auto rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: min(85vh, 720px);
          "
        >
          <!-- Header -->
          <div
            class="px-6 pt-5 pb-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="flex-1 min-w-0">
                <h3
                  id="copy-kanban-spec-title"
                  class="text-title-sm font-semibold flex items-center gap-2"
                  style="color: var(--semantic-text);"
                >
                  <UiIcon name="clipboard" class="w-7 h-7" />
                  Copy spec from…
                </h3>
                <p
                  class="text-dense mt-1.5 leading-relaxed"
                  style="color: var(--semantic-text-dim);"
                >
                  Bulk-copy the column layout from another kanban in this
                  workspace. Tasks on <strong>{{ targetName }}</strong> are not
                  copied.
                </p>
              </div>
              <button
                type="button"
                @click="handleClose"
                data-testid="copy-kanban-spec-close"
                class="shrink-0 w-8 h-8 -mt-1 -mr-1 rounded-lg flex items-center justify-center transition-opacity hover:opacity-70"
                style="color: var(--semantic-text-muted);"
                title="Close"
                aria-label="Close"
              >
                <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
          </div>

          <!-- Scrollable body -->
          <div class="px-6 py-5 flex-1 overflow-y-auto">
            <!-- Source picker (custom dropdown) -->
            <div data-copy-kanban-spec-picker>
              <label
                class="block text-dense font-semibold mb-2 uppercase tracking-wide"
                style="color: var(--semantic-text-dim);"
              >
                Source kanban
              </label>
              <button
                type="button"
                @click.stop="sourceDropdownOpen = !sourceDropdownOpen"
                data-testid="copy-kanban-spec-source-trigger"
                class="w-full flex items-center justify-between gap-2 px-3.5 py-2.5 rounded-lg text-body font-medium transition-colors hover:opacity-90 text-left"
                :style="{
                  backgroundColor: 'var(--semantic-sidebar-bg)',
                  border: '1px solid var(--color-border)',
                  color: selectedSource
                    ? 'var(--semantic-text)'
                    : 'var(--semantic-text-dim)',
                }"
                :aria-expanded="sourceDropdownOpen"
                aria-haspopup="listbox"
              >
                <span class="flex items-center gap-2 truncate">
                  <UiIcon name="folder-open" />
                  <span class="truncate">
                    {{ selectedSource?.name || (availableSources.length === 0 ? 'No other kanbans' : 'Select a kanban…') }}
                  </span>
                </span>
                <svg
                  class="w-4 h-4 shrink-0 transition-transform"
                  :class="sourceDropdownOpen ? 'rotate-180' : ''"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                </svg>
              </button>

              <!-- Dropdown panel -->
              <div
                v-if="sourceDropdownOpen"
                data-testid="copy-kanban-spec-source-list"
                role="listbox"
                class="relative z-10"
              >
                <ul
                  class="absolute left-0 right-0 mt-1.5 rounded-lg shadow-xl overflow-hidden max-h-60 overflow-y-auto"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
                  "
                >
                  <li
                    v-for="item in availableSources"
                    :key="item.id"
                    role="option"
                    :aria-selected="item.id === sourceItemId"
                  >
                    <button
                      type="button"
                      @click.stop="selectSource(item.id)"
                      :data-testid="`copy-kanban-spec-source-option-${item.id}`"
                      class="w-full flex items-center justify-between gap-2 px-3.5 py-2.5 text-body text-left transition-colors hover:opacity-90"
                      :style="{
                        backgroundColor:
                          item.id === sourceItemId
                            ? 'var(--color-violet)'
                            : 'transparent',
                        color:
                          item.id === sourceItemId
                            ? 'var(--color-bg)'
                            : 'var(--semantic-text)',
                      }"
                    >
                      <span class="flex items-center gap-2 truncate">
                        <UiIcon name="folder-open" />
                        <span class="truncate">{{ item.name || '(unnamed)' }}</span>
                      </span>
                      <span
                        v-if="item.id === sourceItemId"
                        aria-hidden="true"
                        class="shrink-0"
                      >✓</span>
                    </button>
                  </li>
                  <li
                    v-if="availableSources.length === 0"
                    data-testid="copy-kanban-spec-empty"
                    class="px-3.5 py-3 text-dense italic"
                    style="color: var(--semantic-text-dim);"
                  >
                    No other kanbans in this workspace. Create another kanban
                    first, then come back to copy its spec.
                  </li>
                </ul>
              </div>

              <!-- Source preview: small list of columns in the source.
                   The loading branch renders the flag `loadSourceColumns`
                   already maintains — without it the preview block is
                   simply absent until the fetch lands, then pops in and
                   shifts the dialog's content mid-interaction. -->
              <div
                v-if="sourceColumnsLoading"
                class="mt-3 rounded-lg overflow-hidden p-3 space-y-2"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                "
                data-testid="copy-kanban-spec-source-loading"
                role="status"
                aria-label="Loading source columns"
              >
                <div
                  v-for="n in 3"
                  :key="n"
                  class="h-6 rounded animate-pulse"
                  style="background-color: var(--semantic-active-bg)"
                />
              </div>
              <div
                v-else-if="sourceColumns.length > 0"
                class="mt-3 rounded-lg overflow-hidden"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                "
              >
                <div
                  class="px-3 py-2 text-meta font-semibold uppercase tracking-wide"
                  style="
                    color: var(--semantic-text-dim);
                    border-bottom: 1px solid var(--color-border);
                  "
                >
                  {{ sourceColumns.length }} column{{ sourceColumns.length === 1 ? '' : 's' }}
                  will be copied
                </div>
                <ul class="px-3 py-2 space-y-1.5 max-h-32 overflow-y-auto">
                  <li
                    v-for="(c, idx) in sourceColumns"
                    :key="c.id"
                    class="flex items-start gap-2 text-dense"
                    style="color: var(--semantic-text);"
                  >
                    <span
                      class="shrink-0 mt-0.5 font-mono text-micro"
                      style="color: var(--semantic-text-dim);"
                    >{{ idx + 1 }}.</span>
                    <span class="flex-1 min-w-0">
                      <span class="font-medium">{{ c.name || '(unnamed)' }}</span>
                      <span
                        v-if="c.description"
                        class="block text-meta mt-0.5 italic truncate"
                        style="color: var(--semantic-text-dim);"
                        :title="c.description"
                      >{{ c.description }}</span>
                    </span>
                  </li>
                </ul>
              </div>
            </div>

            <!-- Mode radio -->
            <fieldset class="mt-6">
              <legend
                class="block text-dense font-semibold mb-3 uppercase tracking-wide"
                style="color: var(--semantic-text-dim);"
              >
                What should happen to {{ targetName }}'s existing columns?
              </legend>
              <label
                class="flex items-start gap-3 px-4 py-3 rounded-lg cursor-pointer mb-2 transition-colors"
                :style="{
                  backgroundColor:
                    mode === 'replace'
                      ? 'var(--color-violet)'
                      : 'var(--semantic-sidebar-bg)',
                  border:
                    mode === 'replace'
                      ? '1px solid var(--color-violet)'
                      : '1px solid var(--color-border)',
                  color:
                    mode === 'replace'
                      ? 'var(--color-bg)'
                      : 'var(--semantic-text)',
                }"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="replace"
                  data-testid="copy-kanban-spec-mode-replace"
                  class="mt-0.5 shrink-0"
                  style="accent-color: var(--color-bg);"
                />
                <span class="flex-1 min-w-0">
                  <span class="text-body font-semibold block">Replace</span>
                  <span
                    class="block text-dense mt-0.5 leading-relaxed"
                    :style="{
                      color:
                        mode === 'replace'
                          ? 'var(--color-bg)'
                          : 'var(--semantic-text-dim)',
                      opacity: mode === 'replace' ? 0.85 : 1,
                    }"
                  >
                    Delete every column on this kanban (existing tasks become
                    unassigned) and replace with the source's columns.
                  </span>
                </span>
              </label>
              <label
                class="flex items-start gap-3 px-4 py-3 rounded-lg cursor-pointer transition-colors"
                :style="{
                  backgroundColor:
                    mode === 'append'
                      ? 'var(--color-violet)'
                      : 'var(--semantic-sidebar-bg)',
                  border:
                    mode === 'append'
                      ? '1px solid var(--color-violet)'
                      : '1px solid var(--color-border)',
                  color:
                    mode === 'append'
                      ? 'var(--color-bg)'
                      : 'var(--semantic-text)',
                }"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="append"
                  data-testid="copy-kanban-spec-mode-append"
                  class="mt-0.5 shrink-0"
                  style="accent-color: var(--color-bg);"
                />
                <span class="flex-1 min-w-0">
                  <span class="text-body font-semibold block">Append</span>
                  <span
                    class="block text-dense mt-0.5 leading-relaxed"
                    :style="{
                      color:
                        mode === 'append'
                          ? 'var(--color-bg)'
                          : 'var(--semantic-text-dim)',
                      opacity: mode === 'append' ? 0.85 : 1,
                    }"
                  >
                    Keep this kanban's existing columns; add the source's
                    columns at the end.
                  </span>
                </span>
              </label>
            </fieldset>
          </div>

          <!-- Actions -->
          <div
            class="px-6 py-4 flex justify-end gap-2 shrink-0"
            style="
              border-top: 1px solid var(--color-border);
              background-color: var(--semantic-sidebar-bg);
            "
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="copy-kanban-spec-cancel"
              class="px-4 py-2 rounded-lg text-body font-medium transition-opacity hover:opacity-80"
              style="
                background-color: transparent;
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @click="handleCopy"
              :disabled="!sourceItemId || availableSources.length === 0"
              data-testid="copy-kanban-spec-confirm"
              class="px-4 py-2 rounded-lg text-body font-semibold transition-all hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Copy spec
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.copy-kanban-spec-modal-enter-active,
.copy-kanban-spec-modal-leave-active {
  transition: opacity 0.2s ease;
}
.copy-kanban-spec-modal-enter-from,
.copy-kanban-spec-modal-leave-to {
  opacity: 0;
}
.copy-kanban-spec-modal-enter-active > div:last-child,
.copy-kanban-spec-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.copy-kanban-spec-modal-enter-from > div:last-child,
.copy-kanban-spec-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
