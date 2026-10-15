<!--
  KanbanColumnEditor — modal for managing kanban columns: add / rename
  / delete. One component, three modes (set via the `mode` prop):

    - 'add':    shows a name input + "Add" button → emits `add(name)`
    - 'rename': shows a name input pre-filled + "Save" button → emits
                `rename(name)`
    - 'delete': shows a confirmation message + "Delete" button →
                emits `delete()`

  The host (WorkspaceItem.vue) is responsible for opening the dialog
  in the right mode, for the confirm/cancel flow on `delete`, and for
  delegating to the store actions. This component is purely
  presentational.

  Public API:
    props:  show, mode ('add' | 'rename' | 'delete'), initialName,
            initialDescription
    emits:  close, add(name, description), rename(name, description),
            delete()
-->
<script setup lang="ts">
import { ref, nextTick, computed, onBeforeUnmount, onMounted, onUpdated } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

type Mode = 'add' | 'rename' | 'delete'

const props = defineProps<{
  show: boolean
  mode: Mode
  initialName?: string
  /** Pre-fill the description field. Only used in 'add' (rarely)
   * and 'rename' modes. Empty string when absent. */
  initialDescription?: string
  /** Pre-fill the completing-column flag (rename mode only). */
  initialIsDone?: boolean
}>()

const emit = defineEmits<{
  close: []
  add: [name: string, description: string]
  rename: [name: string, description: string, isDone: boolean]
  delete: []
}>()

// ─── State ─────────────────────────────────────────────────────────────────

const name = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const description = ref('')
const descriptionInput = ref<HTMLTextAreaElement | null>(null)
// Completing-column flag (rename mode only). Tasks in an
// `is_done` column no longer block their dependents.
const isDone = ref(false)

// 500-char cap matches the project's convention for short text
// fields. The textarea enforces it via `maxlength`; the backend
// does NOT re-validate the cap (Zig error sets grow with every
// constraint; we accept "client says 500, server trusts it" for v1).
const DESCRIPTION_MAX = 500

// ─── Computed labels & description per mode ────────────────────────────────

// Single source of truth for the header + description text. Keeps the
// template branch-free and ensures all 3 modes stay visually consistent.
const headerText = computed(() => {
  if (props.mode === 'add') return 'Add Column'
  if (props.mode === 'rename') return 'Rename Column'
  return 'Delete Column'
})

const descriptionText = computed(() => {
  if (props.mode === 'add') {
    return 'Add a new column to this kanban board'
  }
  if (props.mode === 'rename') {
    return 'Rename this column'
  }
  return 'Delete this column? Tasks in this column will become unassigned.'
})

// The header icon — matches the visual style of AddKanbanDialog.
const headerIcon = computed<UiIconName>(() => {
  if (props.mode === 'delete') return 'trash'
  return 'clipboard'
})

// Show the name input for add / rename modes only; the delete mode
// shows a static confirmation message instead.
const showNameInput = computed(() => props.mode === 'add' || props.mode === 'rename')

const submitLabel = computed(() => {
  if (props.mode === 'add') return 'Add'
  if (props.mode === 'rename') return 'Save'
  return 'Delete'
})

// Whether the submit button is destructive (red). Only the delete
// mode is destructive; add / rename use the standard gradient.
const isDestructive = computed(() => props.mode === 'delete')

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleSubmit = () => {
  if (props.mode === 'delete') {
    emit('delete')
    handleClose()
    return
  }
  const trimmed = name.value.trim()
  if (!trimmed) return
  // Description is optional; trim but allow empty (the backend's
  // "no description" sentinel is the empty string).
  const trimmedDescription = description.value.trim()
  if (props.mode === 'add') {
    emit('add', trimmed, trimmedDescription)
  } else if (props.mode === 'rename') {
    // For rename, we still emit even if the name equals the initial
    // — the parent can choose to no-op. We deliberately do NOT skip
    // the emit because the user explicitly clicked Save.
    emit('rename', trimmed, trimmedDescription, isDone.value)
  }
  handleClose()
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────

// Seed the name field on first render (so a rename modal opened with
// show=true at mount time has the column's name pre-filled, not an
// empty string), and reset + refocus on every subsequent open via
// the open-sync guard below.
name.value = props.initialName ?? ''
isDone.value = props.initialIsDone ?? false
const handleOpen = async () => {
  name.value = props.initialName ?? ''
  description.value = props.initialDescription ?? ''
  isDone.value = props.initialIsDone ?? false
  await nextTick()
  // Focus the name input when it exists; in delete mode there is
  // no input to focus, but focusing the dialog itself is harmless.
  if (showNameInput.value) {
    nameInput.value?.focus()
    nameInput.value?.select()
  }
}

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})

// Open-reset without watch(): seed on mount (initial show=true) and on
// closed->open updates. A Transition before-enter hook cannot do this — it
// never fires on initial mount (no `appear`) and VTU stubs Transition, so
// specs that mount then setProps(show=true) would see empty fields.
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
    <Transition name="kanban-column-editor-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="`kanban-column-editor-title-${mode}`"
        :data-testid="`kanban-column-editor-${mode}`"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: 70vh;
          "
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              :id="`kanban-column-editor-title-${mode}`"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <UiIcon :name="headerIcon" />
              {{ headerText }}
            </h3>
            <p
              class="text-dense mt-1"
              style="color: var(--semantic-text-dim);"
            >
              {{ descriptionText }}
            </p>
          </div>

          <!-- Name input (add / rename) or confirmation text (delete) -->
          <div v-if="showNameInput" class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Column Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              :placeholder="mode === 'add' ? 'In review' : ''"
              :data-testid="`kanban-column-editor-${mode}-name`"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keyup.enter="handleSubmit"
            />
            <label
              class="block text-dense font-medium mb-2 mt-3"
              style="color: var(--semantic-text-dim);"
            >
              Description
              <span
                class="ml-1 text-micro"
                style="color: var(--semantic-text-dim);"
              >(optional — what this column means)</span>
            </label>
            <textarea
              ref="descriptionInput"
              v-model="description"
              :maxlength="DESCRIPTION_MAX"
              rows="3"
              :placeholder="mode === 'add' ? 'e.g. Awaiting code review — must pass CI before merge' : ''"
              :data-testid="`kanban-column-editor-${mode}-description`"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 resize-y"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
                font-family: inherit;
              "
            ></textarea>
            <div
              class="text-micro mt-1 text-right"
              style="color: var(--semantic-text-dim);"
              :data-testid="`kanban-column-editor-${mode}-description-counter`"
            >
              {{ description.length }} / {{ DESCRIPTION_MAX }}
            </div>
            <!-- Completing-column flag (rename mode only). Tasks in
                 an `is_done` column no longer block dependents. -->
            <label
              v-if="mode === 'rename'"
              class="mt-3 flex items-center gap-2 cursor-pointer text-body"
              style="color: var(--semantic-text);"
              :data-testid="`kanban-column-editor-${mode}-is-done-row`"
            >
              <input
                v-model="isDone"
                type="checkbox"
                :data-testid="`kanban-column-editor-${mode}-is-done`"
                class="w-4 h-4 accent-violet-500"
              />
              <span>Completes tasks (unblocks dependents)</span>
            </label>
          </div>
          <div v-else class="px-5 pb-4">
            <!-- Delete-mode confirmation: surface the column name so the
                 user has explicit context on what they're deleting. -->
            <div
              class="text-body px-3 py-2 rounded-lg"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :data-testid="`kanban-column-editor-${mode}-message`"
            >
              <strong>{{ initialName }}</strong>
            </div>
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              @click="handleClose"
              :data-testid="`kanban-column-editor-${mode}-cancel`"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @click="handleSubmit"
              :disabled="showNameInput && !name.trim()"
              :data-testid="`kanban-column-editor-${mode}-submit`"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              :style="isDestructive
                ? 'background: var(--color-red, #ef4444); color: var(--color-bg);'
                : 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);'"
            >
              {{ submitLabel }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal entry/exit animation. Unique name to avoid collisions with
   other dialogs. */
.kanban-column-editor-modal-enter-active,
.kanban-column-editor-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-column-editor-modal-enter-from,
.kanban-column-editor-modal-leave-to {
  opacity: 0;
}

.kanban-column-editor-modal-enter-active > div:last-child,
.kanban-column-editor-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.kanban-column-editor-modal-enter-from > div:last-child,
.kanban-column-editor-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>