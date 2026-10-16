<script lang="ts">
/** Storage key for a line-anchored draft. Exported for tests. */
export function buildDraftKey(
  cwd: string,
  filePath: string,
  startLine: number,
  endLine: number,
): string {
  return `diff-comment:${cwd}:${filePath}:${startLine}-${endLine}`
}

/** Same `## Code Review` markdown shape the sidebar mini-chat used to
 * send to the LLM — now built locally so the comment can be saved or
 * copied without ever touching the chat session. */
export function formatReviewComment(
  filePath: string,
  startLine: number,
  endLine: number,
  context: string,
  message: string,
): string {
  const lineRange = startLine === endLine ? `Line ${startLine}` : `Lines ${startLine}-${endLine}`
  return (
    `## Code Review\n**File:** \`${filePath}\`\n**${lineRange}**\n\n` +
    `\`\`\`\n${context}\n\`\`\`\n\n## Review Comment\n\n${message}`
  )
}

export async function copyTextToClipboard(text: string): Promise<void> {
  try {
    const clipboard = (navigator as Navigator & { clipboard?: Clipboard }).clipboard
    if (clipboard?.writeText) {
      await clipboard.writeText(text)
      return
    }
  } catch {
    // Fall through to the textarea fallback below.
  }
  const ta = document.createElement('textarea')
  ta.value = text
  ta.setAttribute('readonly', '')
  ta.style.position = 'fixed'
  ta.style.opacity = '0'
  document.body.appendChild(ta)
  ta.select()
  try {
    document.execCommand('copy')
  } catch {
    // Best effort only.
  }
  document.body.removeChild(ta)
}

export interface SavedComment {
  start: number
  end: number
  message: string
  savedAt: number
  context: string
}

/** Scan localStorage for saved review comments on a file. Skips entries
 * with empty messages and tolerates legacy raw-string values. Never
 * throws — storage may be unavailable. */
export function listSavedComments(cwd: string, filePath: string): SavedComment[] {
  const out: SavedComment[] = []
  try {
    if (typeof localStorage === 'undefined') return out
    const store = localStorage
    const prefix = `diff-comment:${cwd}:${filePath}:`
    const len = store.length
    for (let i = 0; i < len; i++) {
      let key: string | null = null
      try {
        key = store.key(i)
      } catch {
        continue
      }
      if (!key || !key.startsWith(prefix)) continue
      const suffix = key.slice(prefix.length)
      const m = /^(\d+)-(\d+)$/.exec(suffix)
      if (!m) continue
      const start = parseInt(m[1]!, 10)
      const end = parseInt(m[2]!, 10)
      if (Number.isNaN(start) || Number.isNaN(end)) continue
      let raw: string | null = null
      try {
        raw = store.getItem(key)
      } catch {
        continue
      }
      if (raw == null || raw.length === 0) continue
      let message: unknown = null
      let savedAt = 0
      let context = ''
      try {
        const parsed = JSON.parse(raw) as {
          message?: unknown
          savedAt?: unknown
          context?: unknown
        }
        if (parsed !== null && typeof parsed === 'object' && 'message' in parsed) {
          message = parsed.message
          if (typeof parsed.savedAt === 'number') savedAt = parsed.savedAt
          if (typeof parsed.context === 'string') context = parsed.context
        } else {
          message = raw
        }
      } catch {
        message = raw
      }
      if (typeof message !== 'string' || message.length === 0) continue
      out.push({ start, end, message, savedAt, context })
    }
  } catch {
    // Storage unavailable — no comments.
  }
  return out
}

export function deleteSavedComment(
  cwd: string,
  filePath: string,
  start: number,
  end: number,
): void {
  try {
    localStorage.removeItem(buildDraftKey(cwd, filePath, start, end))
  } catch {
    // Storage unavailable — nothing to delete.
  }
}

export interface DiffCommentSavePayload {
  filePath: string
  startLine: number
  endLine: number
  message: string
  formatted: string
}
</script>

<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'

const props = defineProps<{
  filePath: string
  startLine: number
  endLine: number
  context: string
  cwd: string
}>()

const emit = defineEmits<{
  save: [payload: DiffCommentSavePayload]
  copy: [payload: { formatted: string }]
}>()

const draft = ref('')
const showSaved = ref(false)
const showCopied = ref(false)
let savedTimer: ReturnType<typeof setTimeout> | null = null
let copiedTimer: ReturnType<typeof setTimeout> | null = null

const draftKey = computed(() =>
  buildDraftKey(props.cwd, props.filePath, props.startLine, props.endLine),
)

const formatted = computed(() =>
  formatReviewComment(props.filePath, props.startLine, props.endLine, props.context, draft.value),
)

function loadDraft(): void {
  try {
    const raw = localStorage.getItem(draftKey.value)
    if (!raw) {
      draft.value = ''
      return
    }
    try {
      const parsed = JSON.parse(raw) as { message?: unknown }
      draft.value = typeof parsed.message === 'string' ? parsed.message : raw
    } catch {
      draft.value = raw
    }
  } catch {
    draft.value = ''
  }
}

function flash(kind: 'saved' | 'copied'): void {
  if (kind === 'saved') {
    showSaved.value = true
    if (savedTimer) clearTimeout(savedTimer)
    savedTimer = setTimeout(() => {
      showSaved.value = false
    }, 2000)
  } else {
    showCopied.value = true
    if (copiedTimer) clearTimeout(copiedTimer)
    copiedTimer = setTimeout(() => {
      showCopied.value = false
    }, 2000)
  }
}

function onSave(): void {
  try {
    localStorage.setItem(
      draftKey.value,
      JSON.stringify({
        message: draft.value,
        savedAt: Date.now(),
        context: props.context,
      }),
    )
  } catch {
    // Storage full or unavailable — still emit so the parent can persist.
  }
  flash('saved')
  emit('save', {
    filePath: props.filePath,
    startLine: props.startLine,
    endLine: props.endLine,
    message: draft.value,
    formatted: formatted.value,
  })
}

async function onCopy(): Promise<void> {
  const text = formatted.value
  await copyTextToClipboard(text)
  flash('copied')
  emit('copy', { formatted: text })
}

onMounted(loadDraft)
// Reload the draft when the line anchor changes (the key is derived from
// cwd + path + lines). Prev-value guard on update — same load the watcher
// did; mount is covered by onMounted above.
let prevDraftKey = draftKey.value
onUpdated(() => {
  if (draftKey.value === prevDraftKey) return
  prevDraftKey = draftKey.value
  loadDraft()
})
</script>

<template>
  <div class="flex flex-col gap-2" data-testid="diff-comment-box">
    <div
      class="text-dense truncate"
      style="color: var(--semantic-text-dim)"
      data-testid="diff-comment-range"
    >
      Review {{ filePath }} ({{ startLine }}–{{ endLine }})
    </div>
    <textarea
      v-model="draft"
      class="w-full rounded p-2 text-dense"
      style="
        min-height: 72px;
        background: var(--semantic-input-bg, transparent);
        color: var(--semantic-text);
        border: 1px solid var(--color-border);
      "
      placeholder="Write a review comment…"
      data-testid="diff-comment-input"
    />
    <div class="flex items-center gap-2">
      <button
        type="button"
        class="px-3 py-1.5 text-dense rounded"
        style="background: var(--color-green); color: var(--color-bg)"
        data-testid="diff-comment-save"
        @click="onSave"
      >
        Save
      </button>
      <button
        type="button"
        class="px-3 py-1.5 text-dense rounded"
        style="border: 1px solid var(--color-border); color: var(--semantic-text)"
        data-testid="diff-comment-copy"
        @click="onCopy"
      >
        Copy
      </button>
      <span
        v-if="showSaved"
        class="text-dense"
        style="color: var(--color-green)"
        data-testid="diff-comment-saved"
      >
        Saved
      </span>
      <span
        v-if="showCopied"
        class="text-dense"
        style="color: var(--color-green)"
        data-testid="diff-comment-copied"
      >
        Copied
      </span>
    </div>
  </div>
</template>
