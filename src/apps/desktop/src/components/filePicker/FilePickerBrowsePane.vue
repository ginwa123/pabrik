<script setup lang="ts" generic="T">
import { ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import type { ContentItem, TreeRow } from './filePickerRows'

defineProps<{
  treeRows: TreeRow<T>[]
  entries: ContentItem<T>[]
  currentPath: string
  selectedPath: string
  highlightedIndex: number
  contentEntryCount: number
  isLoading: boolean
  loadError: string | null
  searchQuery: string
  treeExpanded: Record<string, boolean>
  keyFor: (item: T) => string
}>()

const emit = defineEmits<{
  navigate: [path: string]
  toggle: [path: string]
  refresh: []
  itemClick: [item: T]
  itemDoubleClick: [item: T]
  'update:highlightedIndex': [index: number]
}>()

const contentRef = ref<HTMLElement | null>(null)
defineExpose({
  scrollToIndex: (index: number) => {
    const el = contentRef.value?.querySelector(`[data-index="${index}"]`) as HTMLElement | null
    if (el) el.scrollIntoView({ block: 'nearest' })
  },
})
</script>

<template>
  <div class="flex-1 flex overflow-hidden">
    <!-- Tree pane -->
    <div
      class="shrink-0 overflow-y-auto py-1"
      style="
        width: 240px;
        border-right: 1px solid var(--color-border);
        background-color: var(--semantic-sidebar-bg);
      "
      data-testid="file-picker-tree"
    >
      <!-- Loading -->
      <div
        v-if="isLoading && treeRows.length === 0"
        class="px-3 py-2 space-y-1"
      >
        <div
          v-for="n in 3"
          :key="n"
          class="h-5 rounded animate-pulse"
          style="
            background-color: var(--semantic-active-bg);
            width: 80%;
          "
        />
      </div>

      <!-- Error -->
      <div v-else-if="loadError" class="px-3 py-4 text-center">
        <div class="text-title mb-1">⚠️</div>
        <p
          class="text-dense mb-2"
          style="color: var(--semantic-text-dim)"
        >
          {{ loadError }}
        </p>
        <button
          @click="emit('refresh')"
          data-testid="file-picker-retry"
          class="px-2 py-1 text-dense rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Retry
        </button>
      </div>

      <!-- Empty -->
      <div
        v-else-if="treeRows.length === 0"
        class="px-3 py-4 text-center"
      >
        <UiIcon name="folder-open" class="w-6 h-6 mb-1" />
        <p class="text-dense" style="color: var(--semantic-text-dim)">
          No folders
        </p>
      </div>

      <!-- Tree rows -->
      <template v-else>
        <button
          v-for="row in treeRows"
          :key="row.path"
          @click="emit('navigate', row.path)"
          @dblclick.stop="emit('toggle', row.path)"
          :data-testid="`file-picker-tree-${row.path}`"
          class="w-full flex items-center gap-1.5 px-2 py-1 text-dense text-left transition-colors hover:opacity-80"
          :style="{
            paddingLeft: `${0.5 + row.depth * 0.875}rem`,
            backgroundColor:
              row.path === currentPath
                ? 'var(--semantic-active-bg)'
                : 'transparent',
            color: 'var(--semantic-text)',
            fontWeight: row.path === currentPath ? '600' : 'normal',
          }"
        >
          <span
            class="text-micro inline-block w-2 transition-transform duration-150"
            :style="
              treeExpanded[row.path] ? 'transform: rotate(90deg)' : ''
            "
            @click.stop="emit('toggle', row.path)"
            :data-testid="`file-picker-tree-toggle-${row.path}`"
          >▶</span>
          <UiIcon :name="row.icon" />
          <span class="truncate">{{ row.label }}</span>
        </button>
      </template>
    </div>

    <!-- Content pane -->
    <div
      ref="contentRef"
      class="flex-1 overflow-y-auto py-1"
      data-testid="file-picker-content"
    >
      <!-- Loading skeleton -->
      <div
        v-if="isLoading && contentEntryCount === 0"
        class="p-3 space-y-1"
      >
        <div
          v-for="n in 5"
          :key="n"
          class="h-9 rounded animate-pulse"
          style="background-color: var(--semantic-active-bg)"
        />
      </div>

      <!-- Error -->
      <div
        v-else-if="loadError"
        class="px-3 py-4 text-center"
      >
        <div class="text-title mb-1">⚠️</div>
        <p
          class="text-dense mb-2"
          style="color: var(--semantic-text-dim)"
        >
          {{ loadError }}
        </p>
        <button
          @click="emit('refresh')"
          data-testid="file-picker-retry"
          class="px-2 py-1 text-dense rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Retry
        </button>
      </div>

      <!-- Empty -->
      <div
        v-else-if="entries.length === 0"
        class="px-3 py-8 text-center"
      >
        <slot name="empty">
          <UiIcon name="inbox" class="w-6 h-6 mb-1" />
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            {{
              searchQuery
                ? 'No matches'
                : 'Empty folder'
            }}
          </p>
        </slot>
      </div>

      <!-- Items -->
      <template v-else>
        <button
          v-for="(entry, idx) in entries"
          :key="keyFor(entry.item)"
          @click="emit('itemClick', entry.item)"
          @dblclick="emit('itemDoubleClick', entry.item)"
          :data-testid="`file-picker-item-${keyFor(entry.item)}`"
          :data-index="idx"
          :aria-selected="selectedPath === entry.path"
          @mouseenter="emit('update:highlightedIndex', idx)"
          class="w-full flex items-center gap-2 px-3 py-1.5 text-body text-left transition-colors"
          :style="{
            backgroundColor:
              selectedPath === entry.path
                ? 'var(--semantic-active-bg)'
                : highlightedIndex === idx
                  ? 'var(--semantic-hover-bg)'
                  : 'transparent',
            boxShadow:
              selectedPath === entry.path
                ? 'inset 3px 0 0 var(--color-violet)'
                : 'none',
            color: 'var(--semantic-text)',
          }"
        >
          <slot
            name="item"
            :item="entry.item"
            :selected="selectedPath === entry.path"
          >
            <UiIcon :name="entry.icon" class="w-4 h-4 shrink-0" />
            <span class="flex-1 truncate">{{ entry.label }}</span>
            <span
              v-if="entry.subtitle"
              class="text-dense shrink-0"
              style="color: var(--semantic-text-dim)"
            >
              {{ entry.subtitle }}
            </span>
          </slot>
        </button>
      </template>
    </div>
  </div>
</template>

<style scoped>
/* Skeleton shimmer */
@keyframes fp-skeleton-shimmer {
  0% {
    opacity: 0.5;
  }
  50% {
    opacity: 1;
  }
  100% {
    opacity: 0.5;
  }
}

.animate-pulse {
  animation: fp-skeleton-shimmer 1.4s ease-in-out infinite;
}

/* Scrollbar polish for tree + content panes */
.overflow-y-auto::-webkit-scrollbar {
  width: 8px;
}
.overflow-y-auto::-webkit-scrollbar-track {
  background: transparent;
}
.overflow-y-auto::-webkit-scrollbar-thumb {
  background-color: var(--color-border);
  border-radius: 4px;
}
.overflow-y-auto::-webkit-scrollbar-thumb:hover {
  background-color: var(--semantic-text-dim);
}
</style>
