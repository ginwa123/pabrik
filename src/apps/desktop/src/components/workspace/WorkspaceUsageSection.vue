<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useWorkspaceUsageStore } from '../../stores/workspaceUsage'
import type { WorkspaceUsage, WorkspaceUsageRange } from '../../api'
import UsageCacheChart from './UsageCacheChart.vue'
import UsageDailyChart from './UsageDailyChart.vue'
import UsageToolBreakdown from './UsageToolBreakdown.vue'

const props = defineProps<{
  /** The workspace in the URL. The parent keys on it, so a switch remounts this section. */
  workspaceId: string
}>()

const store = useWorkspaceUsageStore()

const RANGES: readonly { value: WorkspaceUsageRange; label: string }[] = [
  { value: '7d', label: '7 days' },
  { value: '30d', label: '30 days' },
  { value: '90d', label: '90 days' },
]

/** Only THIS workspace's answer renders here: a switch must not paint the previous one's totals
 * under the new header while the fetch is in flight. */
const usage = computed<WorkspaceUsage | null>(() =>
  store.usage && store.usage.workspace_id === props.workspaceId ? store.usage : null,
)

const totals = computed(() => usage.value?.totals ?? null)
const isEmpty = computed(() => !!usage.value && (totals.value?.calls ?? 0) === 0)

const compact = (value: number): string => {
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 10_000) return `${Math.round(value / 1000)}k`
  return value.toLocaleString()
}

const perCall = computed(() => {
  const t = totals.value
  if (!t || t.calls === 0) return 0
  return Math.round(t.input_tokens / t.calls)
})

const coverage = computed(() => {
  const t = totals.value
  if (!t || t.calls === 0) return null
  return ((t.calls_with_cache / t.calls) * 100).toFixed(1)
})

const figures = computed(() => {
  const t = totals.value
  return [
    {
      label: 'Cache read rate',
      value:
        t?.cache_hit_rate === null || t?.cache_hit_rate === undefined
          ? '–'
          : `${t.cache_hit_rate}%`,
      muted: t?.cache_hit_rate === null || t?.cache_hit_rate === undefined,
      note: t
        ? `${t.calls_with_cache.toLocaleString()} of ${t.calls.toLocaleString()} calls reported a counter`
        : '',
    },
    {
      label: 'Input tokens',
      value: t ? compact(t.input_tokens) : '–',
      muted: false,
      note: t ? `${compact(perCall.value)} per call` : '',
    },
    {
      label: 'Calls',
      value: t ? t.calls.toLocaleString() : '–',
      muted: false,
      note: t ? `${t.sessions.toLocaleString()} sessions` : '',
    },
    {
      label: 'Tool calls',
      value: t ? t.tool_calls.toLocaleString() : '–',
      muted: false,
      note: 'one row per tool result',
    },
    {
      label: 'Cache counters',
      value: coverage.value === null ? '–' : `${coverage.value}%`,
      muted: true,
      note: 'share of calls that reported any',
    },
  ]
})

function pick(value: WorkspaceUsageRange): void {
  if (store.range === value && usage.value) return
  void store.load(props.workspaceId, value)
}

function retry(): void {
  void store.load(props.workspaceId)
}

onMounted(() => {
  void store.load(props.workspaceId)
})
</script>

<template>
  <section
    class="mx-auto w-full max-w-5xl space-y-5"
    data-testid="workspace-usage-section"
    aria-labelledby="usage-heading"
  >
    <header class="flex flex-wrap items-start justify-between gap-4">
      <div class="space-y-1">
        <h1
          id="usage-heading"
          class="text-title-lg font-semibold"
          style="color: var(--semantic-text)"
        >
          Usage
        </h1>
        <p class="text-dense" style="color: var(--semantic-text-muted)">
          Cache, tokens and tool work for this workspace, derived from every LLM call on record.
        </p>
      </div>
      <div
        class="flex gap-0.5 p-0.5 rounded-lg shrink-0"
        role="group"
        aria-label="Time range"
        style="background: var(--semantic-card-bg)"
      >
        <button
          v-for="option in RANGES"
          :key="option.value"
          type="button"
          class="px-3 py-1.5 rounded-md text-dense font-medium transition-colors duration-150"
          :aria-pressed="store.range === option.value"
          :data-testid="`usage-range-${option.value}`"
          :style="
            store.range === option.value
              ? 'background: var(--semantic-active-bg); color: var(--semantic-text)'
              : 'color: var(--semantic-text-muted)'
          "
          @click="pick(option.value)"
        >
          {{ option.label }}
        </button>
      </div>
    </header>

    <div
      v-if="store.loading && !usage"
      class="rounded-lg p-5 space-y-3 animate-pulse"
      style="background: var(--semantic-card-bg)"
      data-testid="usage-loading"
    >
      <div class="h-3 w-1/3 rounded" style="background: var(--color-bg-p2)" />
      <div class="h-7 w-1/4 rounded" style="background: var(--color-bg-p2)" />
      <div class="h-24 rounded" style="background: var(--color-bg-p1)" />
    </div>

    <div
      v-else-if="store.error && !usage"
      class="rounded-lg p-5"
      style="background: var(--semantic-card-bg)"
      data-testid="usage-error"
    >
      <p class="text-body font-medium" style="color: var(--semantic-text)">
        Could not read the usage totals.
      </p>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">{{ store.error }}</p>
      <button
        type="button"
        class="mt-3 px-3 py-1.5 rounded-md text-dense font-medium"
        style="background: var(--semantic-active-bg); color: var(--semantic-text)"
        data-testid="usage-retry"
        @click="retry"
      >
        Try again
      </button>
    </div>

    <template v-else-if="usage">
      <div
        class="rounded-lg px-5 py-4"
        style="background: var(--semantic-card-bg)"
        data-testid="usage-figures"
      >
        <dl class="grid gap-5 grid-cols-2 md:grid-cols-5">
          <div v-for="figure in figures" :key="figure.label">
            <dt class="text-dense" style="color: var(--semantic-text-muted)">{{ figure.label }}</dt>
            <dd
              class="text-display font-semibold leading-tight tabular-nums mt-1"
              :style="
                figure.muted ? 'color: var(--semantic-text-dim)' : 'color: var(--semantic-text)'
              "
              :data-testid="`usage-figure-${figure.label.toLowerCase().replace(/\s+/g, '-')}`"
            >
              {{ figure.value }}
            </dd>
            <dd class="text-dense mt-1 leading-snug" style="color: var(--semantic-text-muted)">
              {{ figure.note }}
            </dd>
          </div>
        </dl>
      </div>

      <p
        v-if="isEmpty"
        class="rounded-lg p-5 text-body"
        style="background: var(--semantic-card-bg); color: var(--semantic-text-muted)"
        data-testid="usage-empty"
      >
        No LLM call in the last
        {{ store.range === '7d' ? '7 days' : store.range === '90d' ? '90 days' : '30 days' }}. Widen
        the range, or open a workspace that has run an agent.
      </p>

      <template v-else>
        <section
          class="rounded-lg p-5"
          style="background: var(--semantic-card-bg)"
          data-testid="usage-cache-panel"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h2 class="text-title font-semibold" style="color: var(--semantic-text)">
              Cache read rate, call by call
            </h2>
            <span
              v-if="usage.cache_series"
              class="text-dense"
              style="color: var(--semantic-text-muted)"
            >
              {{ usage.cache_series.calls.length }} of
              {{ usage.cache_series.total_calls.toLocaleString() }} calls
            </span>
          </div>

          <template v-if="usage.cache_series">
            <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
              {{ usage.cache_series.session_id }} ·
              {{ usage.cache_series.model || 'model not recorded' }} · the most recent session whose
              provider reported cache.
            </p>
            <div class="mt-5">
              <UsageCacheChart :series="usage.cache_series" />
            </div>
          </template>

          <p
            v-else
            class="text-dense mt-2 leading-relaxed max-w-[68ch]"
            style="color: var(--semantic-text-muted)"
            data-testid="usage-no-telemetry"
          >
            No provider reported a cache counter in this range, so there is no rate to draw. The
            figures above stay at a dash rather than 0%, because a 0% would claim a measurement that
            never happened. Sessions from a provider that does report it appear here with their
            curve.
          </p>
        </section>

        <section
          class="rounded-lg p-5"
          style="background: var(--semantic-card-bg)"
          data-testid="usage-models-panel"
        >
          <h2 class="text-title font-semibold" style="color: var(--semantic-text)">
            Which models fill the column
          </h2>
          <table class="w-full mt-4 border-collapse">
            <thead>
              <tr style="background: var(--color-bg-p1)">
                <th
                  class="text-left text-dense font-medium px-3 py-2"
                  style="color: var(--semantic-text-muted)"
                >
                  Model
                </th>
                <th
                  class="text-right text-dense font-medium px-3 py-2"
                  style="color: var(--semantic-text-muted)"
                >
                  Calls
                </th>
                <th
                  class="text-right text-dense font-medium px-3 py-2"
                  style="color: var(--semantic-text-muted)"
                >
                  Input tokens
                </th>
                <th
                  class="text-right text-dense font-medium px-3 py-2"
                  style="color: var(--semantic-text-muted)"
                >
                  Cache rate
                </th>
                <th
                  class="text-right text-dense font-medium px-3 py-2"
                  style="color: var(--semantic-text-muted)"
                >
                  Reported
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in usage.models"
                :key="row.model || 'none'"
                style="background: var(--semantic-content-bg)"
                data-testid="usage-model-row"
              >
                <td class="text-dense px-3 py-2 break-all">
                  {{ row.model || '(no model recorded)' }}
                </td>
                <td class="text-dense px-3 py-2 text-right tabular-nums">
                  {{ row.calls.toLocaleString() }}
                </td>
                <td class="text-dense px-3 py-2 text-right tabular-nums">
                  {{ compact(row.input_tokens) }}
                </td>
                <td
                  class="text-dense px-3 py-2 text-right tabular-nums"
                  :style="row.cache_hit_rate === null ? 'color: var(--semantic-text-dim)' : ''"
                >
                  {{ row.cache_hit_rate === null ? '–' : `${row.cache_hit_rate}%` }}
                </td>
                <td
                  class="text-dense px-3 py-2 text-right tabular-nums"
                  style="color: var(--semantic-text-muted)"
                >
                  {{ row.calls_with_cache.toLocaleString() }} of {{ row.calls.toLocaleString() }}
                </td>
              </tr>
            </tbody>
          </table>
          <p
            class="text-dense mt-3 leading-relaxed max-w-[68ch]"
            style="color: var(--semantic-text-dim)"
          >
            A dash in Cache rate means that model's calls carried no cache counter. The
            chat-completions usage parser keeps prompt, completion and total tokens only, so a
            provider that reports
            <code class="px-1 rounded-sm" style="background: var(--color-bg-m3)"
              >prompt_cache_hit_tokens</code
            >
            has its counter dropped before the row is written.
          </p>
          <p
            v-if="(totals?.excluded_calls ?? 0) > 0"
            class="text-dense mt-2"
            style="color: var(--semantic-warning)"
            data-testid="usage-excluded"
          >
            {{ totals?.excluded_calls }} call(s) reported a cache read larger than their own prompt.
            They are left out of every rate here, so no figure can pass 100%.
          </p>
        </section>

        <section
          class="rounded-lg p-5"
          style="background: var(--semantic-card-bg)"
          data-testid="usage-daily-panel"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h2 class="text-title font-semibold" style="color: var(--semantic-text)">
              Input tokens per day
            </h2>
            <span class="text-dense" style="color: var(--semantic-text-muted)">
              {{ compact(totals?.input_tokens ?? 0) }} in {{ usage.daily.length }} active days
            </span>
          </div>
          <div class="mt-4">
            <UsageDailyChart :daily="usage.daily" />
          </div>
        </section>

        <section
          class="rounded-lg p-5"
          style="background: var(--semantic-card-bg)"
          data-testid="usage-work-panel"
        >
          <h2 class="text-title font-semibold mb-4" style="color: var(--semantic-text)">
            Where the work went
          </h2>
          <UsageToolBreakdown
            :tools="usage.tools"
            :reasons="usage.finish_reasons"
            :tool-calls="totals?.tool_calls ?? 0"
          />
        </section>
      </template>
    </template>
  </section>
</template>
