<!--
  AddItemDialog — modal for creating a new project from a folder.

  Two-stage modal flow:
    1. This dialog opens with a name input + a "Choose folder" button
    2. Clicking "Choose folder" opens FilePickerDialog (modal 2, on top)
    3. Selecting a folder closes the picker and updates the displayed path
    4. User enters a name and clicks Add → emits `create(name, path)`

  Migrated from an inline folder picker (custom breadcrumb + list) to the
  shared FilePickerDialog component. Net effect: ~200 fewer lines, much
  better UX (dual-pane, search, hidden files toggle, error retry, etc.).

  Public API (unchanged from before the migration):
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
// `true` after the user has interacted with the name field (typed anything OR blurred the field).
// Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
const nameTouched = ref(false)
// Computed error string. `null` when no error should be shown.
// Mirrors `PabrikConfigEditor.vue:295` / `FileInput.vue:543` styling.
const nameError = computed<string | null>(() => {
  if (!nameTouched.value) return null
  if (name.value.trim().length === 0) return 'Name is required'
  return null
})

// ─── Picker data source ──────────────────────────────────────────────────── Adapts the existing
// listFolder/getSystemFolder API to the picker's agnostic (path: string) => Promise<T[]> contract.
// When path is empty we return the system folder root entries.
const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

// ─── Handlers ──────────────────────────────────────────────────────────────
const handleFolderSelected = (path: string) => {
  selectedPath.value = path
  // Close the picker on selection — matches the expected UX (the picker dismisses and the user is
  // returned to the AddItemDialog with the chosen path filled in). The real FilePickerDialog has a
  // `closeOnSelect` prop but it defaults to false, so we close from the parent instead.
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
// dialog opens. We deliberately do NOT preserve selectedPath across open/close — matches the
// pre-migration behavior and keeps the dialog predictable for users.
const handleOpen = async () => {
  name.value = ''
  selectedPath.value = ''
  showPicker.value = false
  // Reset the touched flag so the error doesn't flash on first open.
  // The flag flips on the first @input / @blur after open.
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
    <Transition name="add-item-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-item-title"
        data-testid="add-item-dialog"
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
              id="add-item-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <UiIcon name="folder" />
              Add Project
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              Select a folder to add as a project
            </p>
          </div>

          <!-- Project Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Project Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="My Project"
              data-testid="add-item-name"
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
              data-testid="add-item-name-error"
              style="color: var(--color-red)"
            >
              {{ nameError }}
            </p>
          </div>

          <!-- Folder Selection -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Folder
            </label>
            <button
              type="button"
              @click="showPicker = true"
              data-testid="add-item-choose-folder"
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
              data-testid="add-item-cancel"
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
              data-testid="add-item-submit"
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
    The picker (modal 2). Renders only when showPicker is true. We always
    mount the component (cheap), but its dialog only renders when modelValue
    is true. The picker's own close-on-select behavior closes itself when
    the user picks a folder — we just listen to `select` to update our state.
  -->
  <!--
    The picker (modal 2). We pass the data source functions inline; the
    lambdas use `any` for the item parameter because Vue's template type
    checker can't infer the generic T from inline lambdas (the prop signature
    is `(item: unknown) => string`, contravariant — a typed parameter would
    fail the assignability check). The functions themselves are still fully
    type-safe thanks to the `loadItemsForPicker` return type (FolderEntry).
    The return-type annotations (`as string` / `as boolean`) are explicit so
    the template type-checker can match the prop signatures.
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
    title="Select Project Folder"
    @select="handleFolderSelected"
  />
</template>

<style scoped>
/* Modal entry/exit animation for the AddItemDialog wrapper modal.
   Uses a unique transition name so it doesn't collide with the picker's
   .fp-modal-* transitions (different element, different scope). */
.add-item-modal-enter-active,
.add-item-modal-leave-active {
  transition: opacity 0.2s ease;
}

.add-item-modal-enter-from,
.add-item-modal-leave-to {
  opacity: 0;
}

.add-item-modal-enter-active > div:last-child,
.add-item-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.add-item-modal-enter-from > div:last-child,
.add-item-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
