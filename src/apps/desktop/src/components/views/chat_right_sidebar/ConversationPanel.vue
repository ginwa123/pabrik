<!--
  ConversationPanel — the Conversation tab: the forge's own thread, read
  only. The request body, the issue comments and the review verdicts.

  Every body here is authored by someone who can comment on the repository,
  so it is rendered through helpers/markdown.ts and never as raw HTML — the
  repo ships no DOMPurify, and that helper's escaping is the whole defence.
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import { Effect } from 'effect'
import { getPrConversation, type GitPrConversation } from '../../../api'
import { forgeWording } from '../../../helpers/forgeWording'
import { renderMarkdownHtml } from '../../../helpers/markdown'
import { SyncRemoteError } from '../../../sync/SyncError'
import { runSyncResult } from '../../../sync/runtime'
import ListSkeleton from '../../shell/ListSkeleton.vue'

const props = defineProps<{
  cwd: string
  prUrl?: string
  prProvider?: string
}>()

const emit = defineEmits<{
  /** The thread's size, so the tab can show a count pill. */
  loaded: [count: number]
}>()

const data = ref<GitPrConversation | null>(null)
/** Rendered, never swallowed into an empty thread. */
const error = ref<string | null>(null)
const loading = ref(false)

const forge = computed(() => forgeWording(props.prProvider))

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

async function load() {
  // No change request attached means no conversation to read. Say so; do not fetch.
  if (!props.cwd || !(props.prUrl ?? '').trim()) {
    data.value = null
    error.value = null
    return
  }
  loading.value = true
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        getPrConversation(props.cwd, props.prUrl ?? '', {
          provider: props.prProvider || undefined,
        }),
      catch: (e) => new SyncRemoteError({ op: 'prConversation.load', reason: fail(e) }),
    }),
    'prConversation.load',
  )
  loading.value = false
  if (result.ok) {
    data.value = result.value
    error.value = null
    emit('loaded', result.value.comment_count)
  } else {
    data.value = null
    error.value = result.reason
  }
}

// ─── presentation ───────────────────────────────────────────────────────
const VERDICT: Record<string, { label: string; tone: string }> = {
  APPROVED: { label: 'Approved', tone: 'var(--color-green)' },
  CHANGES_REQUESTED: { label: 'Changes requested', tone: 'var(--semantic-error)' },
  COMMENTED: { label: 'Commented', tone: 'var(--semantic-text-dim)' },
  DISMISSED: { label: 'Dismissed', tone: 'var(--semantic-text-dim)' },
}

const verdict = (state: string) => VERDICT[(state || '').toUpperCase()] ?? null

/** The decision line at the top: the sentence behind "Merging is blocked". */
const decision = computed(() => {
  const value = (data.value?.review_decision ?? '').toUpperCase()
  if (value === 'APPROVED') return { label: 'Approved', tone: 'var(--color-green)' }
  if (value === 'CHANGES_REQUESTED')
    return { label: 'Changes requested', tone: 'var(--semantic-error)' }
  if (value === 'REVIEW_REQUIRED') return { label: 'Review requested', tone: 'var(--color-yellow)' }
  return null
})

/** `2026-10-20T19:26:21Z` → "2h". The raw stamp stays in the title. */
function age(iso: string): string {
  if (!iso) return ''
  const ms = new Date(iso).getTime()
  if (Number.isNaN(ms)) return ''
  const seconds = Math.floor((Date.now() - ms) / 1000)
  if (seconds < 60) return 'just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  const days = Math.floor(seconds / 86400)
  if (days < 30) return `${days}d ago`
  return `${Math.floor(days / 30)}mo ago`
}

const initial = (author: string): string => (author.trim()[0] ?? '?').toUpperCase()

// ─── lifecycle ──────────────────────────────────────────────────────────
onMounted(() => {
  void load()
})

// Reload on binding change (cwd / PR / provider): the thread belongs to the
// previous change request, so it resets with the data.
let prevCwd = props.cwd
let prevPrUrl = props.prUrl
let prevProvider = props.prProvider
onUpdated(() => {
  if (props.cwd === prevCwd && props.prUrl === prevPrUrl && props.prProvider === prevProvider)
    return
  prevCwd = props.cwd
  prevPrUrl = props.prUrl
  prevProvider = props.prProvider
  void load()
})

// The sidebar's ↻ asks for this directly.
defineExpose({ reload: load })
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="pr-conversation-panel">
    <header
      class="flex items-center justify-between px-3 py-2 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <h2 class="text-body font-medium">Conversation</h2>
      <div class="flex items-center gap-2">
        <span
          v-if="decision"
          class="px-1.5 rounded-full text-micro font-semibold"
          :style="{ backgroundColor: 'var(--color-bg-p1)', color: decision.tone }"
          data-testid="conversation-decision"
        >
          {{ decision.label }}
        </span>
        <button
          type="button"
          class="text-dense px-2 py-1 rounded hover:opacity-80"
          style="color: var(--semantic-text-dim)"
          title="Reload the conversation"
          data-testid="conversation-refresh"
          @click="load"
        >
          ↻
        </button>
      </div>
    </header>

    <div
      v-if="error"
      class="px-3 py-2 text-dense break-words"
      style="color: var(--semantic-error)"
      data-testid="conversation-error"
    >
      Could not read the conversation — {{ error }}
    </div>

    <ListSkeleton
      v-else-if="loading && !data"
      :rows="4"
      row-height="h-9"
      test-id="conversation-skeleton"
    />

    <!-- No change request attached: say so rather than render a blank flex div. -->
    <div
      v-else-if="!data"
      class="px-3 py-6 text-dense text-center"
      style="color: var(--semantic-text-dim)"
      data-testid="conversation-no-pr"
    >
      No {{ forge.noun }} attached to this session.
    </div>

    <div v-else class="flex-1 overflow-y-auto min-h-0" data-testid="conversation-thread">
      <p
        v-if="data?.detail"
        class="px-3 py-2 text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="conversation-detail"
      >
        {{ data.detail }}
      </p>

      <article
        v-if="data?.body"
        class="px-3 py-2"
        style="border-bottom: 1px solid var(--color-border)"
        data-testid="conversation-body"
      >
        <div class="flex items-center gap-2 mb-1">
          <span
            class="w-4 h-4 rounded-full flex items-center justify-center text-micro font-semibold shrink-0"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            aria-hidden="true"
            >{{ initial(data.author) }}</span
          >
          <span class="text-dense font-semibold" style="color: var(--semantic-text)">
            {{ data.author }}
          </span>
          <span class="text-micro" style="color: var(--semantic-text-dim)">
            opened this {{ forge.noun }} · {{ age(data.created_at) }}
          </span>
        </div>
        <!-- The forge's own markdown, escaped and rendered by the shared helper. -->
        <div class="text-dense markdown-content" v-html="renderMarkdownHtml(data.body)" />
      </article>

      <article
        v-for="(comment, index) in data?.comments ?? []"
        :key="`comment-${index}`"
        class="px-3 py-2"
        style="border-bottom: 1px solid var(--color-border)"
        data-testid="conversation-comment"
      >
        <div class="flex items-center gap-2 mb-1">
          <span
            class="w-4 h-4 rounded-full flex items-center justify-center text-micro font-semibold shrink-0"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            aria-hidden="true"
            >{{ initial(comment.author) }}</span
          >
          <span class="text-dense font-semibold" style="color: var(--semantic-text)">
            {{ comment.author }}
          </span>
          <span class="text-micro" style="color: var(--semantic-text-dim)">
            commented · {{ age(comment.created_at) }}
          </span>
        </div>
        <div class="text-dense markdown-content" v-html="renderMarkdownHtml(comment.body)" />
      </article>

      <article
        v-for="(review, index) in data?.reviews ?? []"
        :key="`review-${index}`"
        class="px-3 py-2"
        style="border-bottom: 1px solid var(--color-border)"
        data-testid="conversation-review"
      >
        <div class="flex items-center gap-2 mb-1">
          <span
            class="w-4 h-4 rounded-full flex items-center justify-center text-micro font-semibold shrink-0"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            aria-hidden="true"
            >{{ initial(review.author) }}</span
          >
          <span class="text-dense font-semibold" style="color: var(--semantic-text)">
            {{ review.author }}
          </span>
          <span class="text-micro" style="color: var(--semantic-text-dim)">reviewed</span>
          <span
            v-if="verdict(review.state)"
            class="px-1.5 rounded-full text-micro font-semibold"
            :style="{ color: verdict(review.state)?.tone }"
            data-testid="conversation-verdict"
          >
            {{ verdict(review.state)?.label }}
          </span>
        </div>
        <div
          v-if="review.body"
          class="text-dense markdown-content"
          v-html="renderMarkdownHtml(review.body)"
        />
      </article>

      <p
        v-if="(data?.comment_count ?? 0) === 0"
        class="px-3 py-6 text-dense text-center"
        style="color: var(--semantic-text-dim)"
        data-testid="conversation-empty"
      >
        No comments yet on this {{ forge.noun }}.
      </p>
    </div>

    <!-- Read only: the one action is the place where the thread can be written. -->
    <footer
      class="flex items-center gap-2 px-3 py-2 shrink-0"
      style="border-top: 1px solid var(--color-border); background-color: var(--color-bg-m1)"
      data-testid="conversation-footer"
    >
      <a
        :href="prUrl"
        target="_blank"
        rel="noopener"
        class="text-dense font-semibold"
        style="color: var(--semantic-link)"
        data-testid="conversation-open-on-forge"
      >
        Open on {{ forge.forge }} ↗
      </a>
      <span class="text-micro truncate" style="color: var(--semantic-text-dim)">
        comment, approve or request changes there
      </span>
    </footer>
  </div>
</template>
