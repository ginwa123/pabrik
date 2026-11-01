<script setup lang="ts">
import { computed } from 'vue'
import type { WorkspaceUsageCacheSeries } from '../../api'

const props = defineProps<{ series: WorkspaceUsageCacheSeries }>()

const WIDTH = 1000
const HEIGHT = 220
const MISS = 5

const points = computed(() => props.series.calls.filter((c) => c.rate !== null))

const xOf = (index: number): number => {
  const last = Math.max(1, points.value.length - 1)
  return (index / last) * WIDTH
}

const yOf = (rate: number): number => HEIGHT - (Math.max(0, Math.min(100, rate)) / 100) * HEIGHT

const line = computed(() =>
  points.value
    .map((c, i) => `${i === 0 ? 'M' : 'L'}${xOf(i).toFixed(1)},${yOf(c.rate ?? 0).toFixed(1)}`)
    .join(' '),
)

const area = computed(() => `${line.value} L${WIDTH},${HEIGHT} L0,${HEIGHT} Z`)

const misses = computed(() =>
  points.value
    .map((c, i) => ({ x: xOf(i), y: yOf(c.rate ?? 0), rate: c.rate ?? 0, i: c.i }))
    .filter((p) => p.rate < MISS),
)

const steady = computed(() => {
  const rates = points.value
    .slice(1)
    .map((c) => c.rate ?? 0)
    .filter((r) => r >= MISS)
  if (rates.length === 0) return null
  const above = rates.filter((r) => r > 90).length
  return {
    min: Math.round(Math.min(...rates)),
    max: Math.round(Math.max(...rates)),
    above,
    of: rates.length,
  }
})

const coldStart = computed(() => points.value[0] ?? null)

const label = (c: { i: number; at: string; input_tokens: number; rate: number | null }): string =>
  `call ${c.i} at ${c.at.slice(11, 16)}: ${c.rate ?? 0}% of ${c.input_tokens.toLocaleString()} input tokens`
</script>

<template>
  <div>
    <div class="flex gap-3">
      <div
        class="flex flex-col justify-between shrink-0 w-9 text-right text-dense pb-6"
        style="color: var(--semantic-text-dim)"
      >
        <span>100%</span>
        <span>50%</span>
        <span>0%</span>
      </div>
      <div class="flex-1 min-w-0">
        <svg
          :viewBox="`0 0 ${WIDTH} ${HEIGHT}`"
          class="block w-full h-auto"
          role="img"
          :aria-label="`Cache read rate for ${points.length} consecutive calls of ${series.session_id}`"
        >
          <path :d="area" fill="rgb(135 169 135 / 0.12)" />
          <path :d="line" fill="none" stroke="var(--semantic-success)" stroke-width="2" />
          <circle
            v-for="m in misses"
            :key="m.i"
            :cx="m.x"
            :cy="Math.min(m.y, HEIGHT - 4)"
            r="4.5"
            fill="var(--semantic-error)"
          >
            <title>
              {{ label(points[m.i - 1] ?? { i: m.i, at: '', input_tokens: 0, rate: m.rate }) }}
            </title>
          </circle>
        </svg>
        <div class="flex justify-between text-dense pt-1.5" style="color: var(--semantic-text-dim)">
          <span>call 1</span>
          <span>{{ points.length }} calls</span>
        </div>
      </div>
    </div>

    <dl class="grid gap-6 mt-5 pt-4 md:grid-cols-3">
      <div>
        <dt class="text-dense font-medium">Cold start</dt>
        <dd class="text-dense mt-1 leading-relaxed" style="color: var(--semantic-text-muted)">
          Call 1 pays
          <b style="color: var(--semantic-text)">{{
            (coldStart?.input_tokens ?? 0).toLocaleString()
          }}</b>
          tokens at full price. Nothing is cached yet.
        </dd>
      </div>
      <div>
        <dt class="text-dense font-medium">Steady state</dt>
        <dd
          v-if="steady"
          class="text-dense mt-1 leading-relaxed"
          style="color: var(--semantic-text-muted)"
        >
          Calls after the first run between
          <b style="color: var(--semantic-text)">{{ steady.min }}%</b> and
          <b style="color: var(--semantic-text)">{{ steady.max }}%</b>, and
          <b style="color: var(--semantic-text)">{{ steady.above }} of {{ steady.of }}</b>
          land above 90%.
        </dd>
        <dd v-else class="text-dense mt-1" style="color: var(--semantic-text-muted)">
          No call after the first reported a cache read.
        </dd>
      </div>
      <div>
        <dt class="text-dense font-medium">Misses</dt>
        <dd class="text-dense mt-1 leading-relaxed" style="color: var(--semantic-text-muted)">
          <b style="color: var(--semantic-text)">{{ misses.length }}</b>
          {{ misses.length === 1 ? 'call falls' : 'calls fall' }} under {{ MISS }}%. Each one
          re-reads its whole prompt at the input price instead of a tenth of it.
        </dd>
      </div>
    </dl>
  </div>
</template>
