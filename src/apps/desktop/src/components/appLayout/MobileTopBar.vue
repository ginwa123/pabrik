<script setup lang="ts">
defineProps<{ title: string; navOpen?: boolean }>()

defineEmits<{ toggleNav: [] }>()
</script>

<template>
  <header
    class="mobile-top-bar flex items-center gap-1 shrink-0"
    data-testid="mobile-top-bar"
    style="border-bottom: 1px solid var(--color-border)"
  >
    <button
      type="button"
      class="mobile-nav-toggle flex items-center justify-center rounded-md transition-colors duration-150"
      data-testid="mobile-nav-toggle"
      aria-controls="app-sidebar"
      :aria-expanded="navOpen ? 'true' : 'false'"
      :aria-label="navOpen ? 'Close navigation' : 'Open navigation'"
      @click="$emit('toggleNav')"
    >
      <svg
        class="w-4 h-4"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        aria-hidden="true"
      >
        <path d="M4 6h16" />
        <path d="M4 12h16" />
        <path d="M4 18h16" />
      </svg>
    </button>
    <span class="mobile-top-bar-title text-dense font-medium truncate">
      {{ title || 'Pabrik' }}
    </span>
  </header>
</template>
