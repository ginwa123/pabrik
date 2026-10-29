<script setup lang="ts">
import { computed } from 'vue'
import { useRecentFoldersStore } from '../../stores/recentFolders'
import { formatRelativeTime } from '../../helpers/relativeTime'
import UiIcon from '../ui/UiIcon.vue'
import { basenameOf } from './pathUtils'

const emit = defineEmits<{
  selectRow: [path: string]
  pin: [path: string]
  browse: []
}>()

const recentStore = useRecentFoldersStore()
const recentList = computed(() => recentStore.list())
const recentCount = computed(() => recentList.value.length)

function toSqliteUtc(ms: number): string {
  const d = new Date(ms)
  return d.toISOString().replace('T', ' ').slice(0, 19)
}
</script>

<template>
  <div
            class="flex-1 flex flex-col overflow-hidden"
    data-testid="file-picker-recent-body"
  >
    <!-- Empty state -->
    <div
      v-if="recentCount === 0"
      class="flex-1 flex flex-col items-center justify-center gap-3 px-5 py-8 text-center"
      data-testid="file-picker-recent-empty"
    >
      <UiIcon name="folder" class="w-6 h-6" />
      <p class="text-body" style="color: var(--semantic-text)">
        No recent folders yet
      </p>
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        Pick one in Browse to save it here for next time.
      </p>
      <button
        type="button"
        @click="emit('browse')"
        data-testid="file-picker-recent-open-browse"
        class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200 hover:opacity-80"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
      >
        Open Browse
      </button>
    </div>

    <!-- The list -->
    <div
      v-else
      class="flex-1 overflow-y-auto px-5 py-2"
      data-testid="file-picker-recent-list"
    >
      <button
        v-for="entry in recentList"
        :key="entry.path"
        type="button"
        @click="emit('selectRow', entry.path)"
        :data-testid="`file-picker-recent-row-${entry.path}`"
        :title="entry.pinned ? `${entry.path} (pinned)` : entry.path"
        class="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-body text-left transition-colors duration-150 hover:opacity-80"
        style="color: var(--semantic-text);"
      >
        <!-- Folder icon -->
        <UiIcon name="folder" class="w-4 h-4 shrink-0" />
        <!-- Name + path stack -->
        <span class="flex-1 min-w-0 flex flex-col gap-0.5">
          <span class="font-medium truncate">
            {{ basenameOf(entry.path) || entry.path }}
            <span
              v-if="entry.pinned"
              class="ml-1 text-micro px-1.5 py-0.5 rounded uppercase font-semibold"
              style="background-color: var(--color-violet); color: var(--color-bg);"
              data-testid="file-picker-recent-pinned-badge"
            ><UiIcon name="star" /> PINNED</span>
          </span>
          <span
            class="text-dense font-mono truncate"
            style="color: var(--semantic-text-muted)"
          >
            {{ entry.path }}
          </span>
        </span>
        <!-- Right column: time + pin star -->
        <span class="flex items-center gap-2 shrink-0">
          <span
            :data-testid="`file-picker-recent-time-${entry.path}`"
            class="text-dense font-mono"
            style="color: var(--semantic-text-dim)"
          >
            {{ formatRelativeTime(toSqliteUtc(entry.lastUsedAt)) }}
          </span>
          <button
            type="button"
            @click.stop="emit('pin', entry.path)"
            :data-testid="`file-picker-recent-pin-${entry.path}`"
            :title="entry.pinned ? 'Unpin' : 'Pin to keep at top'"
            :aria-label="entry.pinned ? 'Unpin folder' : 'Pin folder'"
            class="w-7 h-7 rounded flex items-center justify-center transition-opacity duration-150 hover:opacity-80"
            :style="{
              color: entry.pinned ? 'var(--color-violet)' : 'var(--semantic-text-dim)',
            }"
          >
            <svg
              v-if="entry.pinned"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="w-4 h-4"
              aria-hidden="true"
            >
              <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
            </svg>
            <svg
              v-else
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              class="w-4 h-4"
              aria-hidden="true"
            >
              <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
            </svg>
          </button>
        </span>
      </button>
    </div>
  </div>
</template>

<style scoped>
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
