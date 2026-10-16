<script setup lang="ts">
// Shared placeholder for list-shaped panels in the chat right sidebar and the git surfaces.
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
