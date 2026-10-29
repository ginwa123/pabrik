<script setup lang="ts">
import { computed, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import type { FilterMode } from './filePickerRows'

const props = defineProps<{
  showFilters: boolean
  filterMode: FilterMode
  showHidden: boolean
  searchQuery: string
}>()

const emit = defineEmits<{
  'update:filterMode': [mode: FilterMode]
  'update:showHidden': [value: boolean]
  'update:searchQuery': [value: string]
  refresh: []
}>()

const query = computed({
  get: () => props.searchQuery,
  set: (value: string) => emit('update:searchQuery', value),
})

const searchInput = ref<HTMLInputElement | null>(null)
defineExpose({ searchInputEl: searchInput })
</script>

<template>
  <div
    class="px-5 py-2 flex items-center gap-2 shrink-0"
    style="border-bottom: 1px solid var(--color-border)"
  >
    <div class="relative flex-1">
      <input
        ref="searchInput"
        v-model="query"
        type="text"
        placeholder="Search... (press / to focus)"
        data-testid="file-picker-search"
        class="w-full pl-7 pr-2 py-1.5 text-dense rounded outline-none transition-all"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
      />
      <UiIcon
        name="search"
        class="absolute left-2 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none"
        style="color: var(--semantic-text-dim)"
      />
    </div>

    <!-- Filter chips (only in 'both' mode) -->
    <div
      v-if="showFilters"
      class="flex items-center gap-1 text-dense"
      role="tablist"
      aria-label="Filter items"
    >
      <button
        v-for="opt in (['all', 'folders', 'files'] as const)"
        :key="opt"
        @click="emit('update:filterMode', opt)"
        :data-testid="`file-picker-filter-${opt}`"
        :aria-pressed="filterMode === opt"
        class="px-2 py-1 rounded transition-all"
        :style="
          filterMode === opt
            ? {
                backgroundColor: 'var(--semantic-active-bg)',
                color: 'var(--semantic-text)',
              }
            : { color: 'var(--semantic-text-dim)' }
        "
      >
        {{
          opt === 'all'
            ? 'All'
            : opt === 'folders'
              ? 'Folders'
              : 'Files'
        }}
      </button>
    </div>

    <!-- Hidden files toggle -->
    <button
      @click="emit('update:showHidden', !showHidden)"
      data-testid="file-picker-hidden-toggle"
      class="px-2 py-1 text-dense rounded transition-all"
      :style="
        showHidden
          ? {
              backgroundColor: 'var(--semantic-active-bg)',
              color: 'var(--semantic-text)',
            }
          : { color: 'var(--semantic-text-dim)' }
      "
      :title="showHidden ? 'Hide hidden files' : 'Show hidden files'"
      :aria-pressed="showHidden"
    >
      <UiIcon name="eye" />
    </button>

    <!-- Refresh -->
    <button
      @click="emit('refresh')"
      data-testid="file-picker-refresh"
      class="px-2 py-1 text-dense rounded transition-all hover:opacity-80"
      style="color: var(--semantic-text-dim)"
      title="Refresh"
    >
      <UiIcon name="refresh" />
    </button>

    <slot name="toolbar" />
  </div>
</template>

<style scoped>
/* Search focus ring */
input:focus {
  box-shadow: 0 0 0 2px rgba(137, 146, 167, 0.2);
}
</style>
