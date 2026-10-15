<!--
  AddMemoryDialog — modal for creating a new LOCAL memory file.

  A local memory lives in `<cwd>/.pabrik/memories/<name>.md` (see
  `LOCAL_MEMORIES_DIR` in `src/modules/agent/tools/memories.zig`).
  The agent's `loadLocalKnowledge` picks up every `.md` in that
  directory on every chat and injects them as the "Local
  Knowledge" section of the system prompt (see
  `src/modules/agent/prompts.zig:263`).

  Distinct from the global memories (in `~/.config/pabrik/memories/`)
  managed via the MemoriesSettings page — global memories apply
  to every project on the machine, while local memories are
  scoped to a specific project directory.

  Two-stage modal flow (mirrors AddItemDialog.vue):
    1. The dialog opens with a name input, a folder picker (defaults
       to the cwd prop), and a content textarea
    2. The user can change the folder via the file picker if the
       default cwd isn't what they want
    3. Clicking "Create":
         - In `mode='standalone'` (default): the dialog calls
           `createLocalMemory(name, content, cwd)` and emits
           `create(name, path)`.
         - In `mode='task'`: the dialog does NOT call the API
           (the backend's `task_create.zig` for memory tasks
           does both the file write AND the task-row insert in
           one POST). It emits `create(name, content, path)` and
           the parent (Sidebar.vue) calls
           `addTask(workspaceId, itemId, { taskType: 'memory', memory: { name, content } })`.

  Public API:
    props:  show (boolean), cwd (string — initial cwd; the user can
                              change it via the folder picker)
            mode ('standalone' | 'task'; default 'standalone')
    emits:  close
            create(name: string, path: string)             // standalone
            create(name: string, content: string, path: string)  // task
-->
<script setup lang="ts">
import { ref, nextTick, onMounted, onUpdated } from 'vue'
import { createLocalMemory, getSystemFolder, listFolder, type FolderEntry } from '../../api'
import { useNotificationStore } from '../../stores/notifications'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(defineProps<{
  show: boolean
  /**    * The initial cwd to scope the new memory to. Used as the starting value of the local `cwd` ref;
   * the user can change it via the folder picker before submitting. Typically passed by the parent
   * as the workspace's first folder item's path, but any valid absolute path works. */
  cwd: string
  /** 'standalone' (default) — the legacy flow: this dialog calls
   * `createLocalMemory` and emits `create(name, path)`.
   * 'task' — the new flow (2026-06-20): this dialog does NOT call
   * the API. It emits `create(name, content, path)` and the parent
   * calls `addTask(..., { taskType: 'memory', memory: { name, content } })`.
   * The backend's `task_create.zig` for memory tasks handles both
   * the file write AND the task-row insert in a single POST, so the
   * parent only needs to make one API call. */
  mode?: 'standalone' | 'task'
}>(), {
  mode: 'standalone',
})

const emit = defineEmits<{
  close: []
  /**
   * The dialog always emits 3 args: `create(name, content, path)`.
   * In `mode='standalone'`, the dialog calls `createLocalMemory`
   * directly and emits the API-returned path (the `content` arg is
   * the value sent to the API; same as the dialog's textarea).
   * In `mode='task'`, the dialog doesn't call the API; the path
   * is the locally-computed `<cwd>/.pabrik/memories/<name>` and
   * the parent uses all 3 args to call addTask.
   *
   * Single 3-tuple shape (instead of a union of 2-tuple / 3-tuple)
   * keeps Vue's emit type system happy and matches the existing
   * AddTaskDialog pattern (always `(name, description)`).
   */
  create: [name: string, content: string, path: string]
}>()

// ─── State ─────────────────────────────────────────────────────────────────

const name = ref('')
// Local cwd — starts as the prop value but the user can change it
// via the file picker. Decoupled from `props.cwd` so the parent
// doesn't need to react to picker events.
const cwd = ref(props.cwd)
const content = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const isSubmitting = ref(false)
const showPicker = ref(false)

const notificationStore = useNotificationStore()

// ─── Validation ─────────────────────────────────────────────────────────────

/**  * Mirrors `memories.isValidMemoryName` from `src/modules/agent/tools/memories.zig:372` — kept in
 * sync so the dialog rejects obvious typos before hitting the server. The server is the source of
 * truth; if the two ever drift, the server-side check returns 400. */
function isValidMemoryName(rawName: string): boolean {
  const trimmed = rawName.trim()
  if (trimmed.length === 0) return false
  if (!trimmed.endsWith('.md')) return false
  if (trimmed.includes('/') || trimmed.includes('\\')) return false
  if (trimmed.includes('..')) return false
  return true
}

// ─── Picker data source ────────────────────────────────────────────────────

// Adapts the existing listFolder/getSystemFolder API to the picker's agnostic (path: string) =>
// Promise<T[]> contract. When path is empty we return the system folder root entries. Same pattern
// as AddItemDialog.vue:44.
const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleFolderSelected = (path: string) => {
  cwd.value = path
  // Close the picker on selection — matches the AddItemDialog
  // UX (the picker dismisses and the user is returned to the
  // AddMemoryDialog with the chosen folder filled in).
  showPicker.value = false
}

const handleCreate = async () => {
  const trimmedName = name.value.trim()
  if (!trimmedName || !content.value) return
  if (!cwd.value) {
    notificationStore.notifyError(
      'Cannot create local memory: no project directory (cwd) is selected. Please pick a folder.',
    )
    return
  }
  if (!isValidMemoryName(trimmedName)) {
    notificationStore.notifyError(
      'Invalid memory name (must end in .md, no /, no .., no \\)',
    )
    return
  }

  isSubmitting.value = true
  try {
    // 'standalone' (default) flow: the dialog calls
    // createLocalMemory directly and emits (name, content, path).
    // The content arg is the same value sent to the API (the
    // dialog's textarea). Parents that don't need content (the
    // legacy standalone flow) can ignore it.
    //
    // The 'task' mode does NOT call the API — it just emits
    // the data the parent needs to call addTask. The parent's
    // task_create.zig will write the .md file and insert the
    // task row in one POST.
    if (props.mode === 'task') {
      const finalPath = `${cwd.value}/.pabrik/memories/${trimmedName}`
      emit('create', trimmedName, content.value, finalPath)
      handleClose()
      return
    }
    const result = await createLocalMemory(trimmedName, content.value, cwd.value)
    // createLocalMemory returns { memory: { name, title, path, size } } on success. The ApiError
    // throw handles the non-2xx case (toast is auto-fired by apiFetch), so reaching this line means
    // the memory exists.
    emit('create', result.memory.name, content.value, result.memory.path)
    handleClose()
  } catch (err) {
    // apiFetch already shows the error toast. The dialog stays open
    // so the user can correct the name/content and try again. No
    // additional notification needed here.
    console.error('[AddMemoryDialog] create failed:', err)
  } finally {
    isSubmitting.value = false
  }
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && !isSubmitting.value) {
    handleClose()
  }
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────

// Reset state on every open — matches AddItemDialog's contract.
// Runs as the open-sync guard below so the fields are
// seeded before the dialog paints.
const handleOpen = async () => {
  name.value = ''
  cwd.value = props.cwd
  content.value = '# New Memory\n\nWrite your notes here.\n'
  isSubmitting.value = false
  showPicker.value = false
  await nextTick()
  nameInput.value?.focus()
}

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
    <Transition name="add-memory-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-memory-title"
        data-testid="add-memory-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-lg mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: 80vh;
          "
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              id="add-memory-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <UiIcon name="note" />
              Add Markdown
            </h3>
            <p
              class="text-dense mt-1"
              style="color: var(--semantic-text-dim);"
            >
              The memory file is created at
              <code class="font-mono break-all">{{ cwd || '(pick a folder below)' }}/.pabrik/memories/</code>
            </p>
          </div>

          <!-- Folder picker -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Folder
            </label>
            <button
              type="button"
              @click="showPicker = true"
              data-testid="add-memory-choose-folder"
              class="w-full px-3 py-2 rounded-lg text-body flex items-center justify-between gap-2 transition-all duration-200 hover:opacity-80"
              :style="{
                backgroundColor: cwd
                  ? 'var(--semantic-active-bg)'
                  : 'var(--semantic-sidebar-bg)',
                border: '1px solid var(--color-border)',
                color: cwd
                  ? 'var(--semantic-text)'
                  : 'var(--semantic-text-dim)',
              }"
            >
              <span
                class="truncate flex-1 text-left font-mono"
                :title="cwd"
              >
                {{ cwd || 'Choose folder...' }}
              </span>
              <span
                v-if="cwd"
                class="text-dense shrink-0"
                style="color: var(--semantic-text-dim);"
                aria-hidden="true"
              >Browse</span>
              <UiIcon
                v-else
                name="folder-open"
                class="w-4 h-4 shrink-0"
                style="color: var(--semantic-text-dim);"
              />
            </button>
          </div>

          <!-- Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Name (must end in <code>.md</code>)
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="my-memory.md"
              data-testid="add-memory-name"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 font-mono"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :disabled="isSubmitting"
              @keyup.enter="handleCreate"
            />
          </div>

          <!-- Content -->
          <div class="px-5 pb-4 flex-1 flex flex-col overflow-hidden">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Initial Content
            </label>
            <textarea
              v-model="content"
              data-testid="add-memory-content"
              rows="6"
              class="flex-1 w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 font-mono resize-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
                min-height: 120px;
              "
              :disabled="isSubmitting"
            />
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2 shrink-0">
            <button
              type="button"
              @click="handleClose"
              :disabled="isSubmitting"
              data-testid="add-memory-cancel"
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
              :disabled="
                isSubmitting ||
                !cwd ||
                !name.trim() ||
                !content.trim() ||
                !isValidMemoryName(name.trim())
              "
              data-testid="add-memory-submit"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(
                  135deg,
                  var(--color-violet),
                  var(--color-blue)
                );
                color: var(--color-bg);
              "
            >
              {{ isSubmitting ? 'Creating...' : 'Create' }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <!--
    The picker (modal 2). Same pattern as AddItemDialog.vue:270.
    Renders only when showPicker is true. The picker's own
    close-on-select behavior closes itself when the user picks
    a folder — we just listen to `select` to update our state.
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
    title="Select Memory Folder"
    @select="handleFolderSelected"
  />
</template>

<style scoped>
/* Modal entry/exit animation. Uses a unique transition name to avoid
   colliding with .add-item-modal-* (different element, same scope). */
.add-memory-modal-enter-active,
.add-memory-modal-leave-active {
  transition: opacity 0.2s ease;
}
.add-memory-modal-enter-from,
.add-memory-modal-leave-to {
  opacity: 0;
}
.add-memory-modal-enter-active > div:last-child,
.add-memory-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.add-memory-modal-enter-from > div:last-child,
.add-memory-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
