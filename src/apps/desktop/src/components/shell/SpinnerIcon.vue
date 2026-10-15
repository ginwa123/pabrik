<script setup lang="ts">
/**  * Shared spinner icon — extracts the SVG-circle idiom previously copy-pasted across ~10 components
 * (AppLayout, RightSidebar, GitCommits, FolderExplorer, SidebarDiffPanel) into one place. New
 * loading UI should use this instead of adding another copy. */
withDefaults(
  defineProps<{
    /** Tailwind size class, e.g. "w-4 h-4". Defaults to w-8 h-8. */
    sizeClass?: string
  }>(),
  { sizeClass: 'w-8 h-8' },
)
</script>

<template>
  <svg
    class="animate-spin"
    :class="sizeClass"
    style="color: var(--color-aqua)"
    viewBox="0 0 24 24"
    fill="none"
    role="status"
    aria-label="Loading"
  >
    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
    <path
      class="opacity-75"
      fill="currentColor"
      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
    />
  </svg>
</template>
