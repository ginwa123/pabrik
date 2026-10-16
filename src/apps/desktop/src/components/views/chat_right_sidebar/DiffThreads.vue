<script setup lang="ts">
import { ref } from 'vue'
import DiffCommentBox, {
  copyTextToClipboard,
  deleteSavedComment,
  formatReviewComment,
  type DiffCommentSavePayload,
  type SavedComment,
} from './DiffCommentBox.vue'

/** The saved review threads for one diff row. Extracted so the unified table and the split table
 * render the SAME block — a thread the user left in one render must keep its wording, its edit
 * affordance and its Copy output in the other. */
const props = defineProps<{
  threads: SavedComment[]
  path: string
  cwd: string
}>()

const emit = defineEmits<{
  save: [payload: DiffCommentSavePayload]
  /** A thread was deleted — the owner re-reads its saved list. */
  changed: []
}>()

const editingKey = ref<string | null>(null)
const copiedKey = ref<string | null>(null)
let copiedTimer: ReturnType<typeof setTimeout> | null = null

const threadKey = (thread: SavedComment) => `${thread.start}-${thread.end}`

/**  * `toLocaleString` on a Date built from a number does not throw — a bad `ts` yields the string
 * "Invalid Date". There is therefore no failure to hide here, and no silent fallback to confuse
 * with a real answer. */
function formatSavedTime(ts: number): string {
  return new Date(ts).toLocaleString()
}

const editThread = (thread: SavedComment) => {
  editingKey.value = threadKey(thread)
}

const cancelEdit = () => {
  editingKey.value = null
}

const deleteThread = (thread: SavedComment) => {
  deleteSavedComment(props.cwd, props.path, thread.start, thread.end)
  emit('changed')
}

const copyThread = async (thread: SavedComment) => {
  await copyTextToClipboard(
    formatReviewComment(props.path, thread.start, thread.end, thread.context, thread.message),
  )
  copiedKey.value = threadKey(thread)
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => {
    copiedKey.value = null
  }, 2000)
}

const onSaved = (payload: DiffCommentSavePayload) => {
  editingKey.value = null
  emit('save', payload)
}
</script>

<template>
  <div
    v-for="thread in props.threads"
    :key="threadKey(thread)"
    class="rounded p-2 mb-1"
    style="border: 1px solid var(--color-border)"
  >
    <div class="text-dense font-medium mb-1" style="color: var(--semantic-text)">
      Comment on lines {{ thread.start }}–{{ thread.end }}
      <span
        v-if="thread.savedAt"
        class="font-normal"
        style="color: var(--semantic-text-dim)"
        data-testid="diff-comment-time"
        >· {{ formatSavedTime(thread.savedAt) }}</span
      >
    </div>
    <div v-if="editingKey === threadKey(thread)">
      <DiffCommentBox
        :file-path="path"
        :start-line="thread.start"
        :end-line="thread.end"
        :context="thread.context"
        :cwd="cwd"
        @save="onSaved"
      />
      <button
        type="button"
        class="text-dense hover:opacity-70 mt-1"
        style="color: var(--color-blue)"
        data-testid="diff-comment-cancel"
        @click="cancelEdit"
      >
        Cancel
      </button>
    </div>
    <div v-else>
      <div
        class="text-dense whitespace-pre-wrap mb-1"
        style="color: var(--semantic-text)"
        data-testid="diff-comment-message"
      >
        {{ thread.message }}
      </div>
      <div class="flex gap-3">
        <button
          type="button"
          class="text-dense hover:opacity-70"
          style="color: var(--color-blue)"
          data-testid="diff-comment-edit"
          @click="editThread(thread)"
        >
          Edit
        </button>
        <button
          type="button"
          class="text-dense hover:opacity-70"
          style="color: var(--color-blue)"
          data-testid="diff-comment-delete"
          @click="deleteThread(thread)"
        >
          Delete
        </button>
        <button
          type="button"
          class="text-dense hover:opacity-70"
          style="color: var(--color-blue)"
          data-testid="diff-comment-copy"
          @click="copyThread(thread)"
        >
          Copy
        </button>
        <span
          v-if="copiedKey === threadKey(thread)"
          class="text-dense"
          style="color: var(--color-green)"
          data-testid="diff-comment-copied"
        >
          Copied
        </span>
      </div>
    </div>
  </div>
</template>
