<!--
  FilePreviewModal — opens a file in a preview dialog when the user
  clicks a `.md-file-chip` in a MarkdownDescription.

  Reuses the existing `GET /api/system/folder?action=read&file=<path>`
  endpoint to fetch the file content (the same one the FolderExplorer
  uses). The path is resolved against the kanban's `cwd` (the
  workspace_item.path).

  Public API:
    props:
      show        boolean
      cwd         string  (the kanban's filesystem root; file paths
                           from MarkdownDescription are relative to this)
      filePath    string  (the path stored in the chip, e.g. "/CLAUDE.md")
      errorMessage string | null  (optional, used by host to surface
                                   fetch failures)
    emits:
      close   []

  Renders:
    - Modal with backdrop + close button (Escape + X)
    - Filename + cwd + relative path in the header
    - File content in a scrollable <pre> with monospace font
    - Loading / error states inline

  Why not use the `present_files` chat card?
    That's for LLM tool output previews in the chat transcript.
    File previews from a description are a different UX —
    they should be inline-modal in the kanban dialog, not chat cards.
    Keeping them separate avoids polluting the global preview
    surface.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onUpdated } from 'vue'
import * as api from '../../api'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    cwd: string
    filePath: string
  }>(),
  {},
)

const emit = defineEmits<{
  close: []
}>()

const content = ref<string>('')
const isLoading = ref(false)
const errorMessage = ref<string | null>(null)

// Compute the absolute path we'll fetch. The chip stores `/path/to/file` (relative to cwd).
const absolutePath = computed<string>(() => {
  const stripped = props.filePath.replace(/^[\\/]+/, '')
  return stripped
})

// Re-fetch whenever the dialog opens OR the file changes: open guard
// (mount with show=true, plus closed->open updates) with a prev-combo
// guard so file switches while open also refetch.
const fetchForDialog = async () => {
  if (!props.show || !props.filePath || !props.cwd) return
  isLoading.value = true
  errorMessage.value = null
  content.value = ''
  try {
    const url = `${api.API_BASE}/system/folder?path=${encodeURIComponent(props.cwd)}&action=read&file=${encodeURIComponent(absolutePath.value)}`
    const response = await fetch(url)
    if (!response.ok) {
      errorMessage.value = `Failed to read file (HTTP ${response.status})`
      return
    }
    const data = (await response.json()) as { content?: string; encoding?: string }
    content.value = data.content ?? ''
  } catch (err) {
    errorMessage.value = err instanceof Error ? err.message : String(err)
  } finally {
    isLoading.value = false
  }
}

const prevFetchKey = ref('')
const fetchKey = () => `${props.show ? '1' : '0'}|${props.filePath}|${props.cwd}`
onMounted(() => {
  prevFetchKey.value = fetchKey()
  void fetchForDialog()
})
onUpdated(() => {
  const key = fetchKey()
  if (key !== prevFetchKey.value) {
    prevFetchKey.value = key
    void fetchForDialog()
  }
})

const handleClose = () => emit('close')
const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}
</script>

<template>
  <Teleport to="body">
    <Transition name="file-preview-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="'file-preview-modal-title'"
        data-testid="file-preview-modal"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6)"
          @click="handleClose"
        />

        <!-- Modal card. Wider than the task detail dialog (max-w-3xl)
             so code-heavy files render comfortably. -->
        <div
          class="relative w-full max-w-3xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            height: min(80vh, calc(100vh - 2rem));
          "
        >
          <!-- Header -->
          <div
            class="px-5 pt-5 pb-4 shrink-0 flex items-center justify-between gap-3"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <div class="min-w-0 flex-1">
              <h3
                id="file-preview-modal-title"
                class="text-lead font-semibold truncate"
                style="color: var(--semantic-text)"
                data-testid="file-preview-modal-title"
              >
                <UiIcon name="file" /> {{ filePath }}
              </h3>
              <div
                class="text-meta truncate"
                style="color: var(--semantic-text-dim)"
                :title="cwd"
                data-testid="file-preview-modal-cwd"
              >
                {{ cwd }}
              </div>
            </div>
            <button
              type="button"
              @click="handleClose"
              data-testid="file-preview-modal-close"
              class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 shrink-0"
              style="color: var(--semantic-text-muted)"
              title="Close"
            >
              <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <!-- Body -->
          <div class="flex-1 overflow-y-auto min-h-0 px-5 py-4">
            <div
              v-if="isLoading"
              class="text-body text-center py-8"
              style="color: var(--semantic-text-dim)"
              data-testid="file-preview-modal-loading"
            >
              <div
                class="w-6 h-6 border-2 rounded-full animate-spin mx-auto mb-2"
                style="border-color: var(--color-violet); border-top-color: transparent"
              />
              Loading file…
            </div>
            <div
              v-else-if="errorMessage"
              class="px-3 py-2 rounded-lg text-body"
              style="
                background-color: rgba(239, 68, 68, 0.12);
                border: 1px solid rgba(239, 68, 68, 0.4);
                color: rgb(220, 38, 38);
              "
              role="alert"
              data-testid="file-preview-modal-error"
            >
              {{ errorMessage }}
            </div>
            <pre
              v-else
              class="text-dense whitespace-pre-wrap break-all"
              style="color: var(--semantic-text); font-family: var(--font-mono); line-height: 1.6"
              data-testid="file-preview-modal-content"
              >{{ content }}</pre>
          </div>

          <!-- Footer -->
          <div
            class="px-5 py-3 shrink-0 flex justify-end gap-2"
            style="border-top: 1px solid var(--color-border)"
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="file-preview-modal-close-button"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.file-preview-modal-enter-active,
.file-preview-modal-leave-active {
  transition: opacity 0.2s ease;
}

.file-preview-modal-enter-from,
.file-preview-modal-leave-to {
  opacity: 0;
}

.file-preview-modal-enter-active > div:last-child,
.file-preview-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.file-preview-modal-enter-from > div:last-child,
.file-preview-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
