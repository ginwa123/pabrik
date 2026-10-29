<!--
  SkillEvalsPanel — the Evals tab.

  Shows the verdicts the agent's self-eval produced, and lets a human accept
  one. Read-only otherwise: the panel never writes a skill itself, it records
  that a human accepted a verdict (the backend's apply endpoint), so exactly
  one place in the system touches a SKILL.MD.

  Deep-linkable: the selected run lives in `?eval_run=` so refresh,
  Back/Forward and shared links restore the same view. A view that only lives
  in component state is unreachable by all three.
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  applySkillEvalResult,
  getSkillEvalsRuns,
  getSkillEvalsSummary,
  type SkillEvalResult,
  type SkillEvalRun,
} from '../../../api'
import { useSseBus } from '../../../helpers/sseBus'
import { resolveWorkspaceId } from '../../../helpers/workspaceScope'

const props = defineProps<{
  /** The session whose evals to show. Empty = every session. */
  sessionId?: string
}>()

const route = useRoute()
const router = useRouter()

const runs = ref<SkillEvalRun[]>([])
const results = ref<SkillEvalResult[]>([])
const counts = ref<{ verdict: string; n: number }[]>([])
const total = ref(0)
const loading = ref(false)
/**  * The failure is held in a ref the template RENDERS, never swallowed into an empty list. "There is
 * nothing new" and "we could not check" must not look the same to the user. */
const error = ref<string | null>(null)
const applying = ref<string | null>(null)
const applyError = ref<string | null>(null)

// ─── the URL param ──────────────────────────────────────────────────────
const readRunParam = (): string => {
  const v = route.query.eval_run
  return typeof v === 'string' ? v : ''
}

const syncRunParam = (runId: string) => {
  const query = { ...route.query }
  if (runId) query.eval_run = runId
  else delete query.eval_run
  // `replace`, not `push`: selecting a run is a view switch, not a navigation
  // step the user should have to Back through.
  void router.replace({ query })
}

const selectedRunId = ref<string>(readRunParam())

/** Empty-state shortcut to the toggle that actually controls this panel. `?section=evals` is the
 * URL-backed tab param PabrikConfigEditor.vue reads, so the destination is deep-linkable and
 * survives a refresh. */
function openSettings() {
  // `evals` is a WORKSPACE-scoped section (Migration 105), so the shortcut has
  // to carry the workspace in the path the way the settings nav does. Pushing
  // `/app/settings` (user scope, General only) showed General instead.
  const wsId = resolveWorkspaceId(route.params.workspaceId, null)
  void router.push({
    path: wsId ? `/app/${wsId}/settings` : '/app/settings',
    query: wsId ? { section: 'evals' } : {},
  })
}

// ─── loading ────────────────────────────────────────────────────────────
async function load() {
  loading.value = true
  error.value = null
  try {
    const [runsRes, summaryRes] = await Promise.all([
      getSkillEvalsRuns({
        session_id: props.sessionId || undefined,
        run_id: selectedRunId.value || undefined,
      }),
      getSkillEvalsSummary(props.sessionId || ''),
    ])
    runs.value = runsRes.runs
    results.value = runsRes.results
    counts.value = summaryRes.counts
    total.value = summaryRes.total
  } catch (e) {
    // A failure must reach the UI as a failure. Returning an empty list here
    // would render "no evals yet" for a backend that is simply unreachable.
    error.value = e instanceof Error ? e.message : String(e)
    runs.value = []
    results.value = []
  } finally {
    loading.value = false
  }
}

function selectRun(runId: string) {
  selectedRunId.value = runId
  syncRunParam(runId)
}

function clearRun() {
  selectedRunId.value = ''
  syncRunParam('')
}

async function apply(result: SkillEvalResult) {
  applying.value = result.id
  applyError.value = null
  try {
    await applySkillEvalResult(result.id, result.verdict === 'delete' ? 'delete' : 'edit')
    await load()
  } catch (e) {
    // A 409 is meaningful: either someone already applied it, or the body
    // changed since the verdict was computed. Both need the user to see it.
    applyError.value = e instanceof Error ? e.message : String(e)
  } finally {
    applying.value = null
  }
}

// ─── lifecycle ──────────────────────────────────────────────────────────
let unsubscribe: (() => void) | null = null

onMounted(() => {
  void load()
  // The backend pushes a lifecycle event when an eval finishes, so the tab
  // refreshes without polling. A listener that throws must not take down the
  // SSE client, so the callback is defensive.
  try {
    const bus = useSseBus()
    unsubscribe = bus.on('skillEvals', (event: { session_id: string }) => {
      if (props.sessionId && event.session_id && event.session_id !== props.sessionId) return
      void load()
    })
  } catch {
    // No bus installed (tests, or a host that never installed it). The panel
    // still works — it just does not live-refresh.
  }
})

onUnmounted(() => {
  unsubscribe?.()
  unsubscribe = null
})

// Reload when the session or the selected run changes: mount covers the initial load, prev-value
// guards on update cover both. The run branch keeps the select+load pairing the old watcher had — a
// param echo of our own selectRun (param already equals selectedRunId) stays load-free.
const readEvalRun = () => (typeof route.query.eval_run === 'string' ? route.query.eval_run : '')
// Subscribed in the template (data-eval-run below) so back/forward navigation that changes
// ?eval_run= re-renders this panel — that render is what fires the onUpdated guard above.
const evalRunParam = computed(readEvalRun)
const prevSessionId = ref(props.sessionId)
const prevEvalRun = ref(readEvalRun())
onMounted(() => {
  prevSessionId.value = props.sessionId
  prevEvalRun.value = readEvalRun()
})
onUpdated(() => {
  const run = readEvalRun()
  if (props.sessionId !== prevSessionId.value) {
    prevSessionId.value = props.sessionId
    prevEvalRun.value = run
    void load()
    return
  }
  if (run !== prevEvalRun.value) {
    prevEvalRun.value = run
    if (run !== selectedRunId.value) {
      selectedRunId.value = run
      void load()
    }
  }
})

// ─── derived ────────────────────────────────────────────────────────────
const missingPaths = (r: SkillEvalResult): string[] => {
  try {
    const parsed = JSON.parse(r.missing_paths || '[]')
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

const verdictClass = (verdict: string): string => {
  switch (verdict) {
    case 'keep':
      return 'text-emerald-400'
    case 'update':
    case 'rewrite':
      return 'text-amber-400'
    case 'delete':
      return 'text-red-400'
    default:
      return 'text-neutral-400'
  }
}

const hasAnything = computed(() => runs.value.length > 0 || results.value.length > 0)
</script>

<template>
  <div
    class="flex flex-col h-full min-h-0"
    data-testid="skill-evals-panel"
    :data-eval-run="evalRunParam"
  >
    <header class="flex items-center justify-between px-3 py-2 border-b border-(--color-border)">
      <h2 class="text-sm font-medium">Skill Evals</h2>
      <div class="flex items-center gap-2">
        <span v-if="total > 0" class="text-xs text-neutral-400" data-testid="evals-total">
          {{ total }} verdict{{ total === 1 ? '' : 's' }}
        </span>
        <button
          class="text-xs px-2 py-1 rounded border border-(--color-border) hover:bg-(--semantic-active-bg)"
          data-testid="evals-refresh"
          @click="load"
        >
          Refresh
        </button>
      </div>
    </header>

    <!-- The failure is rendered, not swallowed. -->
    <div
      v-if="error"
      class="px-3 py-2 text-xs text-red-400 border-b border-(--color-border)"
      data-testid="evals-error"
    >
      Could not load evals: {{ error }}
    </div>

    <div v-if="applyError" class="px-3 py-2 text-xs text-amber-400" data-testid="evals-apply-error">
      {{ applyError }}
    </div>

    <div v-if="loading" class="px-3 py-2 text-xs text-neutral-400" data-testid="evals-loading">
      Loading…
    </div>

    <div
      v-else-if="!hasAnything && !error"
      class="px-3 py-6 text-xs text-neutral-400"
      data-testid="evals-empty"
    >
      Nothing here yet. If Skill Evals is off, turn it on in
      <button
        type="button"
        class="underline underline-offset-2 cursor-pointer"
        style="color: var(--color-violet)"
        data-testid="evals-empty-open-settings"
        @click="openSettings"
      >
        Settings → Skill Evals
      </button>
      and run a session that loads a skill.
    </div>

    <div v-else class="flex-1 min-h-0 overflow-auto">
      <!-- Verdict tally -->
      <ul v-if="counts.length" class="flex flex-wrap gap-2 px-3 py-2" data-testid="evals-counts">
        <li
          v-for="c in counts"
          :key="c.verdict"
          class="text-xs px-2 py-0.5 rounded border border-(--color-border)"
          :class="verdictClass(c.verdict)"
        >
          {{ c.verdict }}: {{ c.n }}
        </li>
      </ul>

      <!-- Runs -->
      <ul class="divide-y divide-(--color-border)" data-testid="evals-runs">
        <li v-for="run in runs" :key="run.id" class="px-3 py-2">
          <button
            class="w-full text-left"
            :data-testid="`evals-run-${run.id}`"
            @click="selectRun(run.id)"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-mono truncate">{{ run.id }}</span>
              <span class="text-xs text-neutral-400">{{ run.status }}</span>
            </div>
            <div class="text-xs text-neutral-500">{{ run.trigger }} · {{ run.session_id }}</div>
          </button>
        </li>
      </ul>

      <!-- Results for the selected run -->
      <div v-if="selectedRunId" class="px-3 py-2">
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-xs font-medium">Results</h3>
          <button
            class="text-xs text-neutral-400 hover:text-neutral-200"
            data-testid="evals-clear-run"
            @click="clearRun"
          >
            Clear
          </button>
        </div>
        <ul class="space-y-2" data-testid="evals-results">
          <li
            v-for="r in results"
            :key="r.id"
            class="rounded border border-(--color-border) p-2"
            :data-testid="`evals-result-${r.id}`"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium">{{ r.skill_name }}</span>
              <span class="text-xs" :class="verdictClass(r.verdict)">{{ r.verdict }}</span>
            </div>
            <p class="text-xs text-neutral-400 mt-1">{{ r.rationale }}</p>
            <div class="flex items-center gap-3 mt-1 text-xs text-neutral-500">
              <span>freshness {{ r.freshness }}</span>
              <span>accuracy {{ r.accuracy }}</span>
              <span>duplication {{ r.duplication }}</span>
              <span v-if="r.shared_fact" data-testid="evals-shared-fact">shared</span>
            </div>
            <ul v-if="missingPaths(r).length" class="mt-1 text-xs text-amber-400">
              <li v-for="p in missingPaths(r)" :key="p" class="font-mono">{{ p }}</li>
            </ul>
            <div class="mt-2">
              <span v-if="r.applied" class="text-xs text-emerald-400" data-testid="evals-applied">
                applied ({{ r.apply_action }})
              </span>
              <button
                v-else
                class="text-xs px-2 py-1 rounded border border-(--color-border) hover:bg-(--semantic-active-bg) disabled:opacity-50"
                :disabled="applying === r.id"
                :data-testid="`evals-apply-${r.id}`"
                @click="apply(r)"
              >
                {{ applying === r.id ? 'Applying…' : 'Apply' }}
              </button>
            </div>
          </li>
        </ul>
      </div>
    </div>
  </div>
</template>
