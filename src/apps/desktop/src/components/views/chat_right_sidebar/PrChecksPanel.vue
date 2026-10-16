<!--
  PrChecksPanel — the Checks tab.

  Answers "which CI job failed, and which step inside it failed on the
  runner" without leaving the app.

  The failure is in the type, not in a try/catch: `load` runs an Effect
  and keeps both outcomes. A PR whose CI is entirely green and a backend
  that could not be reached must not render the same thing — the second
  is an `error` the template shows, not an empty list.
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import { Effect } from 'effect'
import { getPrChecks, type GitPrCheck, type GitPrChecks } from '../../../api'
import { SyncRemoteError } from '../../../sync/SyncError'
import { runSyncResult } from '../../../sync/runtime'
import ListSkeleton from '../../shell/ListSkeleton.vue'

const props = defineProps<{
  cwd: string
  prUrl?: string
  prProvider?: string
}>()

const data = ref<GitPrChecks | null>(null)
/** Rendered, never swallowed into an empty list. */
const error = ref<string | null>(null)
const loading = ref(false)
/** Which failing jobs are expanded. Failed jobs default open — the user
 *  opened this tab to read them. */
const expanded = ref(new Set<string>())

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

async function load() {
  // No PR attached means no CI to ask about. Say so; do not fetch.
  if (!props.cwd || !(props.prUrl ?? '').trim()) {
    data.value = null
    error.value = null
    return
  }
  loading.value = true
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        getPrChecks(props.cwd, props.prUrl ?? '', { provider: props.prProvider || undefined }),
      catch: (e) => new SyncRemoteError({ op: 'prChecks.load', reason: fail(e) }),
    }),
    'prChecks.load',
  )
  loading.value = false
  if (result.ok) {
    data.value = result.value
    error.value = null
    // Default-expand the red jobs, but keep whatever the user already
    // opened or closed for the jobs that are still there.
    const next = new Set(expanded.value)
    for (const c of result.value.checks) {
      if (c.bucket === 'fail' || c.bucket === 'cancel') next.add(c.name)
    }
    expanded.value = next
  } else {
    data.value = null
    error.value = result.reason
  }
}

function toggle(name: string) {
  const next = new Set(expanded.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  expanded.value = next
}

// ─── presentation ───────────────────────────────────────────────────────
const summary = computed(() => data.value?.summary ?? null)

const providerNoun = computed(() =>
  props.prProvider === 'gitlab' ? 'merge request' : 'pull request',
)

const BUCKET_ICON: Record<string, string> = {
  pass: '✓',
  fail: '✗',
  pending: '●',
  skipping: '–',
  cancel: '⊘',
}

const BUCKET_CLASS: Record<string, string> = {
  pass: 'text-emerald-400',
  fail: 'text-red-400',
  pending: 'text-amber-400',
  skipping: 'text-neutral-500',
  cancel: 'text-neutral-400',
}

const STEP_CLASS: Record<string, string> = {
  failure: 'text-red-400',
  timed_out: 'text-red-400',
  cancelled: 'text-amber-400',
  skipped: 'text-neutral-500',
  success: 'text-emerald-400',
}

/** Sorted so the failures are on top — the tab exists to read them. */
const orderedChecks = computed<GitPrCheck[]>(() => {
  const rank = (b: string) => (b === 'fail' ? 0 : b === 'cancel' ? 1 : b === 'pending' ? 2 : 3)
  return [...(data.value?.checks ?? [])].sort((a, b) => rank(a.bucket) - rank(b.bucket))
})

// ─── lifecycle ──────────────────────────────────────────────────────────
let poll: number | undefined

onMounted(() => {
  void load()
  // CI moves on its own, so a stale red is a lie. `showPr` is false when
  // this panel is not mounted, so the panel only polls while visible.
  poll = window.setInterval(() => void load(), 30000)
})

onUnmounted(() => {
  if (poll !== undefined) window.clearInterval(poll)
})

// Reload on binding change (cwd / PR / provider): the expanded set belongs
// to the previous PR, so it resets with the data. Prev-value guard on
// update — same reset+load the watcher did.
let prevChecksCwd = props.cwd
let prevChecksPrUrl = props.prUrl
let prevChecksProvider = props.prProvider
onUpdated(() => {
  if (
    props.cwd === prevChecksCwd &&
    props.prUrl === prevChecksPrUrl &&
    props.prProvider === prevChecksProvider
  )
    return
  prevChecksCwd = props.cwd
  prevChecksPrUrl = props.prUrl
  prevChecksProvider = props.prProvider
  expanded.value = new Set()
  void load()
})

// The sidebar's ↻ asks for this directly.
defineExpose({ reload: load })
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="pr-checks-panel">
    <header
      class="flex items-center justify-between px-3 py-2 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <h2 class="text-body font-medium">CI checks</h2>
      <div class="flex items-center gap-2">
        <span v-if="summary" class="text-dense" style="color: var(--semantic-text-dim)">
          <span v-if="summary.failed" class="text-red-400" data-testid="checks-failed-count">
            {{ summary.failed }} failed
          </span>
          <span v-if="summary.failed && summary.passed"> · </span>
          <span v-if="summary.passed">{{ summary.passed }} passed</span>
          <span v-if="summary.pending"> · {{ summary.pending }} running</span>
          <span v-if="summary.cancelled"> · {{ summary.cancelled }} cancelled</span>
          <span v-if="summary.skipped"> · {{ summary.skipped }} skipped</span>
        </span>
        <button
          type="button"
          class="text-dense px-2 py-1 rounded hover:opacity-80"
          style="color: var(--semantic-text-dim)"
          title="Refresh CI checks"
          data-testid="checks-refresh"
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
      data-testid="checks-error"
    >
      Could not load CI checks — {{ error }}
    </div>

    <ListSkeleton v-if="loading && !data" :rows="5" row-height="h-9" test-id="pr-checks-skeleton" />

    <div
      v-else-if="!error && data && data.checks.length === 0"
      class="px-3 py-6 text-dense text-center"
      style="color: var(--semantic-text-dim)"
      data-testid="checks-empty"
    >
      No CI checks reported for this {{ providerNoun }}.
    </div>

    <!-- No PR attached — say so rather than rendering a blank flex div,
         which read as "the panel is broken". -->
    <div
      v-else-if="!error && !data"
      class="px-3 py-6 text-dense text-center"
      style="color: var(--semantic-text-dim)"
      data-testid="checks-no-pr"
    >
      No pull request attached to this session.
    </div>

    <div v-else class="flex-1 overflow-y-auto min-h-0" data-testid="checks-list">
      <div
        v-if="data?.steps_truncated"
        class="mx-3 mt-2 px-2 py-1.5 rounded text-dense"
        style="
          background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
          color: var(--semantic-text);
        "
        data-testid="checks-truncated"
      >
        Too many failing workflows to read every job's steps in one go — some are shown without
        them.
      </div>

      <div
        v-for="check in orderedChecks"
        :key="check.name"
        class="border-b"
        style="border-color: var(--color-border)"
        :data-testid="`checks-row-${check.name}`"
      >
        <div class="flex items-center gap-2 px-3 py-1.5">
          <span
            class="text-dense shrink-0"
            :class="BUCKET_CLASS[check.bucket] ?? 'text-neutral-400'"
            data-testid="checks-row-icon"
          >
            {{ BUCKET_ICON[check.bucket] ?? '?' }}
          </span>
          <span
            class="text-dense truncate flex-1"
            style="color: var(--semantic-text)"
            :title="check.name"
            data-testid="checks-row-name"
          >
            {{ check.name }}
          </span>
          <a
            v-if="check.link"
            :href="check.link"
            target="_blank"
            rel="noopener"
            class="text-dense px-1 rounded hover:opacity-80"
            style="color: var(--color-aqua)"
            title="Open on the forge"
            data-testid="checks-row-link"
            @click.stop
          >
            ↗
          </a>
          <button
            v-if="check.steps.length > 0"
            type="button"
            class="text-dense px-1 rounded hover:opacity-80"
            style="color: var(--semantic-text-dim)"
            :title="expanded.has(check.name) ? 'Hide steps' : 'Show steps'"
            :data-testid="`checks-toggle-${check.name}`"
            @click="toggle(check.name)"
          >
            {{ expanded.has(check.name) ? '▾' : '▸' }}
          </button>
        </div>

        <div
          v-if="check.steps_error"
          class="px-3 pb-1.5 pl-8 text-dense break-words"
          style="color: var(--semantic-error)"
          data-testid="checks-steps-error"
        >
          {{ check.steps_error }}
        </div>

        <ul
          v-if="check.steps.length > 0 && expanded.has(check.name)"
          class="pb-1 pl-8"
          :data-testid="`checks-steps-${check.name}`"
        >
          <li
            v-for="step in check.steps"
            :key="`${check.name}-${step.number}-${step.name}`"
            class="flex items-center gap-2 py-0.5"
            :data-testid="`checks-step-${step.name}`"
          >
            <span
              class="text-dense shrink-0"
              :class="STEP_CLASS[step.conclusion] ?? 'text-neutral-400'"
            >
              {{ step.conclusion === 'failure' ? '✗' : step.conclusion === 'skipped' ? '–' : '✓' }}
            </span>
            <span class="text-dense truncate" style="color: var(--semantic-text-dim)">{{
              step.name
            }}</span>
          </li>
        </ul>
      </div>
    </div>
  </div>
</template>
