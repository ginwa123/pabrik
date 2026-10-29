<script setup lang="ts">
defineProps<{
  displayBranch: string
  changeCount: number
}>()
</script>
<template>
    <div
      class="flex items-center gap-2 px-3 h-9 shrink-0"
      style="background-color: var(--color-bg-m1); border-bottom: 1px solid var(--color-border)"
    >
      <svg
        class="w-3.5 h-3.5 shrink-0"
        style="color: var(--semantic-text-dim)"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path
          d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
        />
      </svg>
      <span
        class="font-mono text-dense font-medium truncate min-w-0"
        style="color: var(--semantic-text)"
        data-testid="sidebar-diff-branch"
      >
        {{ displayBranch || 'Git' }}
      </span>
      <span
        v-if="changeCount > 0"
        class="ml-auto shrink-0 px-1.5 rounded-full text-micro font-semibold"
        style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
        data-testid="sidebar-diff-count"
      >
        {{ changeCount }}
      </span>
    </div>
</template>
