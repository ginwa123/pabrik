<script setup lang="ts">
import { ref, onMounted, onUpdated } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import {
  getLocalMemoryDetail,
  createLocalMemory,
  updateLocalMemory,
  deleteLocalMemory,
  type MemoryDetail as MemoryDetailData,
} from '../../api'

const props = defineProps<{
  memoryName: string | null
  cwd: string
  isCreating?: boolean
}>()

const emit = defineEmits<{
  memoryDeleted: [name: string]
  memorySaved: []
  error: [message: string]
  cancelCreate: []
}>()

type Mode = 'view' | 'edit' | 'create' | 'empty'

const detail = ref<MemoryDetailData | null>(null)
const isLoading = ref(false)
const isSaving = ref(false)
const isDeleting = ref(false)
const error = ref<string | null>(null)
const mode = ref<Mode>('empty')

// Editable copies (used by edit and create modes)
const editName = ref('')
const editContent = ref('')

// Delete confirmation modal
const showDeleteConfirm = ref(false)

/**
 * Human-readable byte size (1 KB = 1024 bytes).
 */
const formatSize = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

// Drive mode from prop changes. `isCreating=true` short-circuits the fetch — set up an empty create
// form. Prev-value guard on update — same fetch/setup the watcher did; the mount call covers the
// initial load (the old `immediate: true`).
async function syncMemoryMode(newName: string | null, creating: boolean) {
  // Create mode: skip the fetch entirely, set up an empty create form.
  if (creating) {
    detail.value = null
    editName.value = ''
    editContent.value = '# New Memory\n\nWrite your notes here.\n'
    mode.value = 'create'
    error.value = null
    showDeleteConfirm.value = false
    return
  }
  if (!newName) {
    detail.value = null
    error.value = null
    showDeleteConfirm.value = false
    mode.value = 'empty'
    return
  }

  isLoading.value = true
  error.value = null
  try {
    const result = await getLocalMemoryDetail(newName, props.cwd)
    if (result.error_message) {
      error.value = result.error_message
      detail.value = null
      mode.value = 'empty'
    } else if (result.memory) {
      detail.value = result.memory
      editName.value = result.memory.name
      editContent.value = result.memory.content
      mode.value = 'view'
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load memory'
    mode.value = 'empty'
  } finally {
    isLoading.value = false
  }
}

let prevMemoryName: string | null = props.memoryName
let prevMemoryCreating = props.isCreating
let prevMemoryCwd = props.cwd
onMounted(() => {
  prevMemoryName = props.memoryName
  prevMemoryCreating = props.isCreating
  prevMemoryCwd = props.cwd
  void syncMemoryMode(props.memoryName, props.isCreating ?? false)
})
onUpdated(() => {
  if (
    props.memoryName === prevMemoryName &&
    props.isCreating === prevMemoryCreating &&
    props.cwd === prevMemoryCwd
  )
    return
  prevMemoryName = props.memoryName
  prevMemoryCreating = props.isCreating
  prevMemoryCwd = props.cwd
  void syncMemoryMode(props.memoryName, props.isCreating ?? false)
})

// --- Edit mode handlers ---
const startEdit = () => {
  if (!detail.value) return
  editContent.value = detail.value.content
  mode.value = 'edit'
}

const cancelEdit = () => {
  if (detail.value) {
    editContent.value = detail.value.content
  }
  mode.value = 'view'
}

const saveEdit = async () => {
  if (!detail.value) return
  isSaving.value = true
  try {
    await updateLocalMemory(detail.value.name, editContent.value, props.cwd)
    mode.value = 'view'
    // Refresh the local size to reflect the new content length (avoid a second round-trip to the
    // server — the only field that changes on edit is size, and we can compute it client-side from
    // the new content string).
    if (detail.value) {
      detail.value = {
        ...detail.value,
        size: editContent.value.length,
      }
    }
    emit('memorySaved')
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to save memory')
  } finally {
    isSaving.value = false
  }
}

// --- Create mode handlers ---
const startCreate = () => {
  detail.value = null
  editName.value = ''
  editContent.value = '# New Memory\n\nWrite your notes here.\n'
  mode.value = 'create'
}

const saveCreate = async () => {
  const trimmedName = editName.value.trim()
  if (!trimmedName) {
    emit('error', 'Name cannot be empty')
    return
  }
  if (!trimmedName.endsWith('.md')) {
    emit('error', 'Name must end in .md')
    return
  }
  if (trimmedName.includes('/') || trimmedName.includes('\\') || trimmedName.includes('..')) {
    emit('error', 'Name cannot contain path separators')
    return
  }
  isSaving.value = true
  try {
    const result = await createLocalMemory(trimmedName, editContent.value, props.cwd)
    mode.value = 'view'
    // createMemory returns Memory (no content); synthesize the full detail
    // from what we just wrote so the view-mode <pre> has content to show.
    detail.value = {
      name: result.memory.name,
      title: result.memory.title,
      path: result.memory.path,
      size: result.memory.size,
      content: editContent.value,
    }
    editName.value = result.memory.name
    // editContent.value is already correct (same string we just persisted);
    // result.memory is Memory (no content field), so no re-assignment needed.
    emit('memorySaved')
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to create memory')
  } finally {
    isSaving.value = false
  }
}

// --- Create-mode cancel ---
const handleCancelCreate = () => {
  emit('cancelCreate')
}

// --- Delete handlers ---
const confirmDelete = () => {
  showDeleteConfirm.value = true
}

const cancelDelete = () => {
  showDeleteConfirm.value = false
}

const handleDelete = async () => {
  if (!detail.value) return
  isDeleting.value = true
  try {
    const result = await deleteLocalMemory(detail.value.name, props.cwd)
    if (result.success) {
      showDeleteConfirm.value = false
      emit('memoryDeleted', detail.value.name)
    } else {
      emit('error', result.error_message || 'Failed to delete memory')
    }
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to delete memory')
  } finally {
    isDeleting.value = false
  }
}

// Expose `startCreate` so the parent (MemoriesSettings) can trigger
// create mode from the "+ New Memory" button in the list header.
defineExpose({ startCreate })
</script>

<template>
  <div class="memory-detail h-full flex flex-col overflow-hidden">
    <!-- Empty state: nothing selected, offer to create -->
    <div v-if="mode === 'empty'" class="flex-1 flex flex-col items-center justify-center gap-4 p-6">
      <p class="text-body" style="color: var(--semantic-text-muted)">
        Select a memory to view, or create a new one.
      </p>
      <button
        @click="startCreate"
        class="px-4 py-2 rounded-lg text-body font-medium"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: white;
        "
      >
        + New Memory
      </button>
    </div>

    <!-- Loading state — skeleton holds the detail pane's height instead
         of collapsing it to one centered row. -->
    <div
      v-else-if="isLoading"
      class="flex-1 overflow-y-auto p-4"
      data-testid="local-memory-detail-skeleton"
    >
      <div class="space-y-3">
        <div
          class="h-6 w-1/2 rounded animate-pulse"
          style="background-color: var(--semantic-active-bg)"
        />
        <div
          v-for="w in ['100%', '96%', '88%', '92%', '70%']"
          :key="w"
          class="h-4 rounded animate-pulse"
          :style="{ width: w, backgroundColor: 'var(--semantic-active-bg)' }"
        />
      </div>
    </div>

    <!-- Error state -->
    <div v-else-if="error" class="flex-1 flex items-center justify-center">
      <p class="text-body" style="color: var(--color-red)">{{ error }}</p>
    </div>

    <!-- Create mode -->
    <div v-else-if="mode === 'create'" class="flex-1 flex flex-col overflow-hidden">
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border)">
        <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-muted)">
          Name (must end in .md)
        </label>
        <input
          v-model="editName"
          type="text"
          placeholder="my-memory.md"
          class="w-full px-3 py-2 rounded-lg border text-body"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border-color: var(--color-border);
          "
        />
      </div>
      <div class="flex-1 overflow-hidden p-4 flex flex-col">
        <textarea
          v-model="editContent"
          class="flex-1 w-full px-3 py-2 rounded-lg border text-body font-mono resize-none"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border-color: var(--color-border);
          "
        />
      </div>
      <div
        class="p-4 flex gap-2 justify-end shrink-0"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="handleCancelCreate"
          :disabled="isSaving"
          class="px-4 py-2 rounded-lg text-body font-medium"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >
          Cancel
        </button>
        <button
          @click="saveCreate"
          :disabled="isSaving"
          class="px-4 py-2 rounded-lg text-body font-medium"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: white;
          "
        >
          {{ isSaving ? 'Creating...' : 'Create' }}
        </button>
      </div>
    </div>

    <!-- View / Edit mode (shared shell, different buttons + body) -->
    <div v-else-if="detail" class="flex-1 flex flex-col overflow-hidden">
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border)">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-3 min-w-0">
            <UiIcon name="brain" size-class="w-4.5 h-4.5" />
            <h3 class="text-lead font-semibold truncate" style="color: var(--semantic-text)">
              {{ detail.title }}
            </h3>
          </div>
          <div v-if="mode === 'view'" class="flex gap-2 shrink-0">
            <button
              @click="startEdit"
              class="px-3 py-1 text-dense rounded"
              style="
                background-color: var(--semantic-card-bg);
                color: var(--semantic-text-muted);
                border: 1px solid var(--color-border);
              "
            >
              Edit
            </button>
            <button
              @click="confirmDelete"
              class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200"
              style="background-color: rgba(239, 68, 68, 0.1); color: var(--color-red)"
              title="Delete memory"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </button>
          </div>
        </div>
        <p class="text-dense truncate" style="color: var(--semantic-text-dim)">
          <span class="font-medium">Path:</span> {{ detail.path }} · {{ formatSize(detail.size) }}
        </p>
      </div>

      <div class="flex-1 overflow-hidden p-4 flex flex-col">
        <pre
          v-if="mode === 'view'"
          class="flex-1 overflow-y-auto text-dense p-4 rounded whitespace-pre-wrap font-mono"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted)"
          >{{ detail.content }}</pre>
        <textarea
          v-else
          v-model="editContent"
          class="flex-1 w-full px-3 py-2 rounded-lg border text-body font-mono resize-none"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border-color: var(--color-border);
          "
        />
      </div>

      <div
        v-if="mode === 'edit'"
        class="p-4 flex gap-2 justify-end shrink-0"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="cancelEdit"
          :disabled="isSaving"
          class="px-4 py-2 rounded-lg text-body font-medium"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >
          Cancel
        </button>
        <button
          @click="saveEdit"
          :disabled="isSaving"
          class="px-4 py-2 rounded-lg text-body font-medium"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: white;
          "
        >
          {{ isSaving ? 'Saving...' : 'Save' }}
        </button>
      </div>
    </div>

    <!-- Delete Confirmation Modal -->
    <div
      v-if="showDeleteConfirm"
      class="absolute inset-0 flex items-center justify-center z-10"
      style="background-color: rgba(0, 0, 0, 0.5)"
      data-testid="memory-detail-delete-modal"
      @keydown.esc="cancelDelete"
    >
      <div
        class="rounded-xl p-6 max-w-sm mx-4"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <h3 class="text-lead font-semibold mb-2" style="color: var(--semantic-text)">
          Delete Memory?
        </h3>
        <p class="text-body mb-4" style="color: var(--semantic-text-muted)">
          Are you sure you want to delete "<strong>{{ detail?.name }}</strong
          >"? This action cannot be undone.
        </p>
        <div class="flex gap-3 justify-end">
          <button
            @click="cancelDelete"
            :disabled="isDeleting"
            class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
            style="
              background-color: var(--semantic-content-bg);
              color: var(--semantic-text-muted);
              border: 1px solid var(--color-border);
            "
            data-testid="memory-detail-delete-cancel"
          >
            Cancel
          </button>
          <button
            @click="handleDelete"
            :disabled="isDeleting"
            class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
            style="background-color: var(--color-red); color: white"
            data-testid="memory-detail-delete-confirm"
          >
            {{ isDeleting ? 'Deleting...' : 'Delete' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
