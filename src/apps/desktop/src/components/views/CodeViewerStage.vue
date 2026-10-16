<script setup lang="ts">
import CodeEditor from './CodeEditor.vue'
import type { FolderEntry } from '../../api'

/** The code viewer's three states — loading spinner, error, file — in one place, so both hosts
 * render the identical surface: - `ChatView`'s center column (beside the chat-owned right sidebar). */
defineProps<{
  file: FolderEntry
  content: string
  loading: boolean
  error: string | null
  cwd?: string
  line?: number | null
}>()

const emit = defineEmits<{
  close: []
}>()
</script>

<template>
  <div
    class="code-viewer-stage flex flex-col h-full min-h-0 overflow-hidden"
    data-testid="code-viewer-stage"
  >
    <!-- Loading state -->
    <div
      v-if="loading"
      class="flex-1 flex items-center justify-center"
      data-testid="code-viewer-loading"
    >
      <svg
        class="animate-spin w-8 h-8"
        style="color: var(--color-aqua)"
        viewBox="0 0 24 24"
        fill="none"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
    </div>

    <!-- Error state (never a silent blank) -->
    <div
      v-else-if="error"
      class="flex-1 flex flex-col items-center justify-center"
      data-testid="code-viewer-error"
    >
      <span class="text-title-lg mb-2">⚠️</span>
      <p class="text-body" style="color: var(--semantic-text-dim)">{{ error }}</p>
      <button
        type="button"
        @click="emit('close')"
        class="mt-4 px-4 py-2 rounded-lg text-body"
        style="background-color: var(--color-border); color: var(--semantic-text)"
        data-testid="code-viewer-error-close"
      >
        Close
      </button>
    </div>

    <!-- The file itself -->
    <CodeEditor
      v-else
      :file-path="file.path"
      :file-name="file.name"
      :content="content"
      :cwd="cwd"
      :line="line ?? undefined"
      @close="emit('close')"
    />
  </div>
</template>
