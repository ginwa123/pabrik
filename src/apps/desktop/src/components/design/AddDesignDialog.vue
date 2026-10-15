<!--
  AddDesignDialog — modal for creating a new design-mode project.

  Two-input modal flow (mirrors AddKanbanDialog):
    1. User types a name in the name input
    2. User clicks the "Choose folder..." button to open the
       FilePickerDialog (modal 2, on top) and selects a project
       root on disk
    3. User clicks Add → emits `create(name, path)`
    4. Parent (Sidebar) calls workspacesStore.addDesignItem(...)
       which POSTs to /api/workspaces/:wsId/items/design with the
       chosen path as `workspace_items.path` (the cwd for every
       chat session / design_page created under this design item)

  The path is REQUIRED. Without it, every chat session in this
  design's pages / tasks is cwd-less — git/file tools fail with
  "no such directory". Existing design items created before this
  dialog existed can backfill via the DesignView "Set project
  root" banner.

  Public API:
    props:  show (boolean)
    emits:  close, create(name: string, path: string)
-->
<script setup lang="ts">
import { ref, computed, nextTick, onBeforeUnmount, onMounted, onUpdated } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  show: boolean
}>()

const emit = defineEmits<{
  close: []
  create: [name: string, path: string]
}>()

// ─── State ─────────────────────────────────────────────────────────────────
const name = ref('')
const selectedPath = ref('')
const showPicker = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)
// Same "touched + visible error" UX as AddItemDialog and AddKanbanDialog. After the user types (or
// blurs) the name field empty/whitespace, the dialog shows "Name is required" below the input so
// the disabled Add button is self-explanatory.
// Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
const nameTouched = ref(false)
const nameError = computed<string | null>(() => {
  if (!nameTouched.value) return null
  if (name.value.trim().length === 0) return 'Name is required'
  return null
})

// ─── Picker data source ──────────────────────────────────────────────────── Adapts the existing
// listFolder/getSystemFolder API to the picker's agnostic (path: string) => Promise<T[]> contract.
// Same helper as AddItemDialog + AddKanbanDialog — duplicated here (not extracted) to keep the
// dialogs independently editable.
const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

// ─── Handlers ──────────────────────────────────────────────────────────────
const handleFolderSelected = (path: string) => {
  selectedPath.value = path
  showPicker.value = false
}

const handleCreate = () => {
  const trimmedName = name.value.trim()
  if (trimmedName && selectedPath.value) {
    emit('create', trimmedName, selectedPath.value)
    handleClose()
  }
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────── Reset state when the
// dialog opens. We deliberately do NOT preserve either the name or the selected path across
// open/close so the dialog is predictable for users.
const handleOpen = async () => {
  name.value = ''
  selectedPath.value = ''
  showPicker.value = false
  // Reset the touched flag so the error doesn't flash on first open.
  nameTouched.value = false
  await nextTick()
  nameInput.value?.focus()
}

onBeforeUnmount(() => {
  document.body.style.overflow = ''
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
    <Transition name="add-design-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-design-title"
        data-testid="add-design-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6)"
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
              id="add-design-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <UiIcon name="palette" />
              Add Design Project
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              Create a new design workspace
            </p>
          </div>

          <!-- Design Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Design Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Design System"
              data-testid="add-design-name"
              :aria-invalid="nameError !== null"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${nameError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="nameTouched = true"
              @blur="nameTouched = true"
              @keyup.enter="handleCreate"
            />
            <p
              v-if="nameError"
              class="text-dense mt-1"
              data-testid="add-design-name-error"
              style="color: var(--color-red)"
            >
              {{ nameError }}
            </p>
          </div>

          <!-- Project Root (folder picker) -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Project Root
              <span class="ml-1 text-micro" style="color: var(--semantic-text-dim)"
                >(used as cwd for chat sessions)</span
              >
            </label>
            <button
              type="button"
              @click="showPicker = true"
              data-testid="add-design-choose-folder"
              class="w-full px-3 py-2 rounded-lg text-body flex items-center justify-between gap-2 transition-all duration-200 hover:opacity-80"
              :style="{
                backgroundColor: selectedPath
                  ? 'var(--semantic-active-bg)'
                  : 'var(--semantic-sidebar-bg)',
                border: '1px solid var(--color-border)',
                color: selectedPath ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
              }"
            >
              <span class="truncate flex-1 text-left font-mono" :title="selectedPath">
                {{ selectedPath || 'Choose folder...' }}
              </span>
              <span
                v-if="selectedPath"
                class="text-dense shrink-0"
                style="color: var(--semantic-text-dim)"
                aria-hidden="true"
                >Browse</span
              >
              <UiIcon
                v-else
                name="folder-open"
                class="w-4 h-4 shrink-0"
                style="color: var(--semantic-text-dim)"
              />
            </button>
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              @click="handleClose"
              data-testid="add-design-cancel"
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
              @click="handleCreate"
              :disabled="!name.trim() || !selectedPath"
              data-testid="add-design-submit"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
  <!--
    FilePickerDialog (modal 2). Same data source functions as
    AddItemDialog + AddKanbanDialog — the picker is data-source
    agnostic, so we just hand it our `loadItemsForPicker` (which
    adapts listFolder / getSystemFolder to the picker's generic
    contract). The picker closes on select so the user returns
    here with the chosen path filled in.
  -->
  <FilePickerDialog
    v-model="showPicker"
    mode="folder"
    :load-items="loadItemsForPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="true"
    :enable-recent-history="true"
    title="Select Design Project Root"
    @select="handleFolderSelected"
  />
</template>

<style scoped>
/* Modal entry/exit animation for the AddDesignDialog wrapper modal.
   Uses a unique transition name so it doesn't collide with other
   dialogs that share the .modal-* namespace. */
.add-design-modal-enter-active,
.add-design-modal-leave-active {
  transition: opacity 0.2s ease;
}

.add-design-modal-enter-from,
.add-design-modal-leave-to {
  opacity: 0;
}

.add-design-modal-enter-active > div:last-child,
.add-design-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.add-design-modal-enter-from > div:last-child,
.add-design-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
