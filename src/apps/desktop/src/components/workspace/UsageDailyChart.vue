<script setup lang="ts">
import { computed } from 'vue'
import type { WorkspaceUsageDailyPoint } from '../../api'

const props = defineProps<{ daily: WorkspaceUsageDailyPoint[] }>()

const WIDTH = 1000
const HEIGHT = 150
const GAP = 10

/** The endpoint only returns days that had a call, so a silent day would vanish from the bars
 * instead of reading as a zero. Fill the interior so the shape is the truth. */
const slots = computed<{ day: string; tokens: number; calls: number }[]>(() => {
  const byDay = new Map(props.daily.map((d) => [d.day, d]))
  if (!byDay.size) return []
  const days = [...byDay.keys()].sort()
  const first = Date.parse(`${days[0]}T00:00:00Z`)
  const last = Date.parse(`${days[days.length - 1]}T00:00:00Z`)
  if (!Number.isFinite(first) || !Number.isFinite(last)) {
    return props.daily.map((d) => ({ day: d.day, tokens: d.input_tokens, calls: d.calls }))
  }
  const out: { day: string; tokens: number; calls: number }[] = []
  for (let t = first; t <= last; t += 86_400_000) {
    const key = new Date(t).toISOString().slice(0, 10)
    const hit = byDay.get(key)
    out.push({ day: key, tokens: hit?.input_tokens ?? 0, calls: hit?.calls ?? 0 })
  }
  return out
})

const peak = computed(() => Math.max(1, ...slots.value.map((s) => s.tokens)))

const barWidth = computed(() => {
  const count = Math.max(1, slots.value.length)
  return (WIDTH - GAP * (count - 1)) / count
})

const peakDay = computed<{ day: string; tokens: number; calls: number } | null>(() => {
  const list = slots.value
  if (!list.length) return null
  return list.reduce((a, b) => (b.tokens > a.tokens ? b : a))
})

function barX(index: number): number {
  return index * (barWidth.value + GAP)
}

function barHeight(tokens: number): number {
  return Math.max(tokens > 0 ? 2 : 0, (tokens / peak.value) * HEIGHT)
}

const shortDay = (day: string): string => `${day.slice(8, 10)} ${day.slice(5, 7)}`
</script>

<template>
  <div>
    <svg
      :viewBox="`0 0 ${WIDTH} ${HEIGHT}`"
      class="block w-full h-auto"
      role="img"
      :aria-label="`Input tokens per day, ${slots.length} days, peaking at ${peak.toLocaleString()} tokens`"
    >
      <rect
        v-for="(slot, index) in slots"
        :key="slot.day"
        :x="barX(index)"
        :y="HEIGHT - barHeight(slot.tokens)"
        :width="barWidth"
        :height="barHeight(slot.tokens)"
        rx="1"
        :fill="slot.day === peakDay?.day ? 'var(--color-yellow)' : 'var(--color-bg-p2)'"
      >
        <title>
          {{ slot.day }}: {{ slot.tokens.toLocaleString() }} tokens in {{ slot.calls }} calls
        </title>
      </rect>
    </svg>
    <div class="flex justify-between text-dense pt-1.5" style="color: var(--semantic-text-dim)">
      <span>{{ slots[0] ? shortDay(slots[0].day) : '' }}</span>
      <span>{{ slots[slots.length - 1] ? shortDay(slots[slots.length - 1]!.day) : '' }}</span>
    </div>
  </div>
</template>
