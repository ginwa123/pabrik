<script setup lang="ts">
// Shared sidebar loading placeholder.
withDefaults(
  defineProps<{
    /** How many placeholder rows to render. */
    rows?: number
    /** Test id for specs (per-section so tests stay independent). */
    testId?: string
  }>(),
  { rows: 5, testId: 'sidebar-skeleton' },
)
</script>

<template>
  <div :data-testid="testId" role="status" aria-label="Loading">
    <div v-for="n in rows" :key="n" class="px-[var(--sb-gutter)] py-1">
      <div
        class="h-[var(--sb-row)] rounded animate-pulse"
        style="background-color: var(--semantic-active-bg)"
      />
    </div>
  </div>
</template>
