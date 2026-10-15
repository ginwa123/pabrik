<script setup lang="ts">
/** "Create worktree" dialog. Mounted by ChatView.vue when the user clicks "Create worktree" in the
 * WorktreeMenu (no-worktree branch). The dialog is a small folder-picker + name input. */
/** The user picks a PARENT DIRECTORY via the FilePickerDialog (modal), then types a SHORT BASENAME
 * (e.g. "auth-fix", "bug-123") for the worktree itself. The dialog composes the final absolute path
 * as `${parentDir}/${basename}` and emits `create(path)`. */
/** The parent sends a system message to the LLM asking it to call
 * set_git_worktree(path=<full_path>). Migrated from an inline FolderExplorer + breadcrumb + "Up"
 * button to the shared FilePickerDialog component. */
/** Net effect: ~150 fewer lines, the picker is a proper modal with search/hidden-files/keyboard
 * nav, and the user no longer has to type paths in a tiny text input. Public API (unchanged from
 * before the migration): props:  initialCwd? */
/** (absolute path used as the starting parent dir) emits:  create(path: string), close() The tool
 * handles path validation (must be absolute, no .., no null bytes, ≤ 4096 chars, basename matches
 * [A-Za-z0-9._-]{1,100}) and the worktree-add subprocess. */
/** The branch defaults to worktree/<basename(path)> in the tool, so the LLM doesn't need to pass
 * it. */
import { ref, computed, onMounted, nextTick, onBeforeUnmount } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  /** Absolute path used as the initial parent directory (typically the session cwd). */
  initialCwd?: string
}>()

const emit = defineEmits<{
  (e: 'create', path: string): void
  (e: 'close'): void
}>()

// ─── State ─────────────────────────────────────────────────────────────────
// Parent directory of the new worktree. Starts at initialCwd (the
// session cwd), or falls back to '/' if not provided.
const parentDir = ref(
  props.initialCwd && props.initialCwd.trim() !== '' ? props.initialCwd : '/',
)

// Basename of the new worktree (e.g. "auth-fix", "bug-123").
const basename = ref('')

const isSubmitting = ref(false)
const showPicker = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)

// ─── Picker data source ──────────────────────────────────────────────────── Adapts the existing
// listFolder/getSystemFolder API to the picker's agnostic (path: string) => Promise<T[]> contract.
// When path is empty we return the system folder root entries.
const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

// ─── Computed ──────────────────────────────────────────────────────────────
// Final path that will be sent to set_git_worktree. Avoids double-slash
// when parentDir is "/".
const fullPath = computed(() => {
  const base = parentDir.value.endsWith('/')
    ? parentDir.value.slice(0, -1)
    : parentDir.value
  const trimmed = basename.value.trim()
  if (trimmed === '') return `${base}/`
  return `${base}/${trimmed}`
})

// Can the user submit? Need a non-empty basename + a valid-looking
// parent dir. The tool's validatePath is the source of truth; this is
// only the client-side guard to disable the button.
const canSubmit = computed(() => {
  return (
    !isSubmitting.value &&
    basename.value.trim() !== '' &&
    parentDir.value.trim() !== ''
  )
})

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleFolderSelected = (path: string) => {
  parentDir.value = path
  // Close the picker on selection — matches the expected UX (the picker dismisses and the user is
  // returned to the CreateWorktreeDialog with the chosen path filled in). The real FilePickerDialog
  // has a `closeOnSelect` prop but it defaults to false, so we close from the parent instead.
  showPicker.value = false
}

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && !isSubmitting.value) emit('close')
}

const onSubmit = () => {
  if (!canSubmit.value) return
  isSubmitting.value = true
  emit('create', fullPath.value)
  // Don't close here — the parent may show an error inline. Parent
  // decides when to close (on success, on error, on Cancel).
}

const onClose = () => {
  if (!isSubmitting.value) emit('close')
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────
// Focus the basename input on mount. The dialog is mounted by the parent
// (ChatView) via v-if, so this fires exactly once per open/close cycle.
onMounted(() => {
  nextTick(() => nameInput.value?.focus())
})

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      @click.self="onClose"
      @keydown="handleKeydown"
      role="dialog"
      aria-modal="true"
      aria-labelledby="create-worktree-title"
      data-testid="create-worktree-dialog"
    >
      <!-- Backdrop -->
      <div
        class="absolute inset-0 backdrop-blur-md"
        style="background: rgba(0, 0, 0, 0.6);"
        @click="onClose"
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
          max-height: 80vh;
        "
      >
        <!-- Header -->
        <div class="px-5 pt-5 pb-4 flex items-start justify-between">
          <div>
            <h3
              id="create-worktree-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <UiIcon name="tree" />
              Create a worktree
            </h3>
            <p
              class="text-dense mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Pick a parent directory and a short name
            </p>
          </div>
          <button
            type="button"
            @click="onClose"
            :disabled="isSubmitting"
            data-testid="create-worktree-close"
            class="opacity-60 hover:opacity-100 text-lead shrink-0"
            style="color: var(--semantic-text);"
          >
            ✕
          </button>
        </div>

        <!-- Parent directory -->
        <div class="px-5 pb-4">
          <label
            class="block text-dense font-medium mb-2"
            style="color: var(--semantic-text-dim);"
          >
            Parent directory
          </label>
          <button
            type="button"
            @click="showPicker = true"
            data-testid="create-worktree-choose-parent"
            class="w-full px-3 py-2 rounded-lg text-body flex items-center justify-between gap-2 transition-all duration-200 hover:opacity-80"
            :style="{
              backgroundColor: parentDir && parentDir !== '/'
                ? 'var(--semantic-active-bg)'
                : 'var(--semantic-sidebar-bg)',
              border: '1px solid var(--color-border)',
              color: parentDir && parentDir !== '/'
                ? 'var(--semantic-text)'
                : 'var(--semantic-text-dim)',
            }"
          >
            <span
              class="truncate flex-1 text-left font-mono"
              :title="parentDir"
            >
              {{ parentDir === '/' ? 'Choose parent directory…' : parentDir }}
            </span>
            <span
              v-if="parentDir && parentDir !== '/'"
              class="text-dense shrink-0"
              style="color: var(--semantic-text-dim);"
              aria-hidden="true"
            >
              Change
            </span>
            <UiIcon
              v-else
              name="folder-open"
              class="w-4 h-4 shrink-0"
              style="color: var(--semantic-text-dim);"
            />
          </button>
        </div>

        <!-- Basename + hint -->
        <div class="px-5 pb-4">
          <label
            class="block text-dense font-medium mb-2"
            style="color: var(--semantic-text-dim);"
          >
            Name
          </label>
          <input
            ref="nameInput"
            v-model="basename"
            data-testid="create-worktree-name"
            type="text"
            placeholder="auth-fix"
            class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 font-mono"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            @keyup.enter="onSubmit"
          />
          <p
            class="text-micro mt-2"
            style="color: var(--semantic-text-dim);"
          >
            The worktree will be created at
            <code style="font-family: monospace;">{{ fullPath }}</code>.
            The branch will be auto-derived as
            <code style="font-family: monospace;">worktree/{{ basename || '&lt;name&gt;' }}</code>.
            The parent directory must already exist.
          </p>
        </div>

        <!-- Actions -->
        <div class="px-5 pb-5 flex justify-end gap-2">
          <button
            type="button"
            @click="onClose"
            :disabled="isSubmitting"
            data-testid="create-worktree-cancel"
            class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
          >
            Cancel
          </button>
          <button
            type="button"
            @click="onSubmit"
            :disabled="!canSubmit"
            data-testid="create-worktree-submit"
            class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
            :class="!canSubmit ? 'opacity-50 cursor-not-allowed' : 'hover:opacity-80'"
            style="
              background-color: var(--color-violet);
              color: white;
            "
          >
            {{ isSubmitting ? 'Creating…' : 'Create' }}
          </button>
        </div>
      </div>
    </div>

    <!-- File picker (modal on top of this dialog) -->
    <FilePickerDialog
      v-model="showPicker"
      :load-items="loadItemsForPicker"
      :key-for="(item: FolderEntry) => item.path"
      :path-for="(item: FolderEntry) => item.path"
      :is-expandable="(item: FolderEntry) => item.is_directory"
      :label-for="(item: FolderEntry) => item.name"
      :initial-path="parentDir"
      :selected-path="parentDir"
      :enable-recent-history="true"
      title="Select parent directory"
      @select="handleFolderSelected"
    />
  </Teleport>
</template>
