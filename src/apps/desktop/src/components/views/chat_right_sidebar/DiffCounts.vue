<script setup lang="ts">
/** `+N / -N` for one file row — the GitHub/GitLab line-count chip. Shared by the sidebar's PR list
 * and its worktree lists so the two can never drift apart in colour, size, or spacing. */
defineProps<{
  added: number | null
  removed: number | null
}>()
</script>

<template>
  <span
    v-if="added !== null && removed !== null"
    class="shrink-0 font-mono text-micro tabular-nums flex items-center gap-1"
    :title="`+${added} / -${removed} lines`"
    data-testid="diff-counts"
  >
    <span style="color: var(--color-green)">+{{ added }}</span>
    <span style="color: var(--color-red)">-{{ removed }}</span>
  </span>
</template>
