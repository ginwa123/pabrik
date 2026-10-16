<script setup lang="ts">
// Shared placeholder for list-shaped settings surfaces. Why a shared component: ProfilesSection,
// SubAgentsSection, McpServersSection and WebSearchSection are pure-prop and render their
// EmptyState the instant `modelValue.length === 0`.
withDefaults(
  defineProps<{
    /** How many placeholder rows to render. */
    rows?: number
    /** Test id for specs (per-section so tests stay independent). */
    testId?: string
  }>(),
  { rows: 3, testId: 'settings-skeleton' },
)
</script>

<template>
  <div :data-testid="testId" role="status" aria-label="Loading">
    <div v-for="n in rows" :key="n" class="py-1">
      <div
        class="h-[52px] rounded-md animate-pulse"
        style="background-color: var(--semantic-active-bg)"
      />
    </div>
  </div>
</template>
