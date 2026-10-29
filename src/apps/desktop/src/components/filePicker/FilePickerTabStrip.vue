<script setup lang="ts">
defineProps<{
  activeTab: 'recent' | 'browse'
  recentCount: number
}>()

const emit = defineEmits<{
  'update:activeTab': [tab: 'recent' | 'browse']
}>()
</script>

<template>
  <div
    class="px-5 py-1 flex items-center gap-1 shrink-0"
    style="border-bottom: 1px solid var(--color-border);"
    role="tablist"
    aria-label="Folder picker view"
  >
    <button
      type="button"
      role="tab"
      :aria-selected="activeTab === 'recent'"
      data-testid="file-picker-tab-recent"
      @click="emit('update:activeTab', 'recent')"
      class="relative px-3 h-9 text-dense font-medium transition-colors duration-150 inline-flex items-center gap-1.5 shrink-0"
      :style="{
        color: activeTab === 'recent' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">Recent</span>
      <span
        v-if="recentCount > 0"
        data-testid="file-picker-tab-recent-count"
        class="text-micro px-1.5 rounded font-mono"
        :style="{
          backgroundColor: activeTab === 'recent' ? 'var(--color-violet)' : 'var(--semantic-text-muted)',
          color: 'var(--color-bg)',
        }"
      >{{ recentCount }}</span>
      <span
        v-if="activeTab === 'recent'"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet);"
        aria-hidden="true"
      />
    </button>
    <button
      type="button"
      role="tab"
      :aria-selected="activeTab === 'browse'"
      data-testid="file-picker-tab-browse"
      @click="emit('update:activeTab', 'browse')"
      class="relative px-3 h-9 text-dense font-medium transition-colors duration-150 inline-flex items-center gap-1.5 shrink-0"
      :style="{
        color: activeTab === 'browse' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">Browse</span>
      <span
        v-if="activeTab === 'browse'"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet);"
        aria-hidden="true"
      />
    </button>
    <span class="flex-1" aria-hidden="true" />
  </div>
</template>
