<script setup lang="ts">
// Shared sidebar loading placeholder.
//
// Why a shared component: PINNED + RECENT (ChatsList), PROJECTS
// (ProjectsList) and DOCUMENTS (DocumentsList) all had their own
// loading story — plain "Loading..." text, a header spinner, or
// nothing at all — so a slow boot flashed empty sections before
// rows arrived. One skeleton keeps the layout stable and the
// behaviour identical everywhere.
// Shape mirrors the sidebar row: full-width bar at --sb-row height with the same gutter, using the
// same animate-pulse + --semantic-active-bg treatment as FilePickerDialog's skeleton.
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
