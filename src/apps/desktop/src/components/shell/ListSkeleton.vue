<script setup lang="ts">
// Shared placeholder for list-shaped panels in the chat right sidebar
// and the git surfaces.
//
// Why a shared component: SidebarDiffPanel (PR + Files tabs),
// GitCommits, PrChecksPanel and SkillEvalsPanel each hand-rolled their
// own loading story — a centered spinner, or plain "Loading…" text.
// A spinner in a `flex-1` container collapses the panel's scroll
// height to ~40px and then jumps to full height when data lands; the
// skeleton holds the layout instead. Shape mirrors a generic list row: full-width bar at
// `rowHeight` with the same animate-pulse + --semantic-active-bg treatment as SidebarSkeleton.vue.
withDefaults(
  defineProps<{
    /** How many placeholder rows to render. */
    rows?: number
    /** Test id for specs (per-panel so tests stay independent). */
    testId?: string
    /** Tailwind height class for one row, e.g. `h-7`. */
    rowHeight?: string
  }>(),
  { rows: 6, testId: 'list-skeleton', rowHeight: 'h-7' },
)
</script>

<template>
  <div :data-testid="testId" role="status" aria-label="Loading" class="p-2 space-y-2">
    <div
      v-for="n in rows"
      :key="n"
      :class="[rowHeight, 'rounded animate-pulse']"
      style="background-color: var(--semantic-active-bg)"
    />
  </div>
</template>
