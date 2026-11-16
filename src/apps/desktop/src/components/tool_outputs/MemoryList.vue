<script setup lang="ts">
import { ref, onMounted } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import ListSkeleton from '../shell/ListSkeleton.vue'
import { getMemories, type Memory } from '../../api'

const props = defineProps<{
  selectedMemoryName: string | null
}>()

const memories = ref<Memory[]>([])
const isLoading = ref(true)
const error = ref<string | null>(null)

const emit = defineEmits<{
  selectMemory: [name: string]
}>()

const loadMemories = async () => {
  isLoading.value = true
  error.value = null
  try {
    const result = await getMemories()
    memories.value = result.memories || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load memories'
    console.error('Failed to load memories:', err)
  } finally {
    isLoading.value = false
  }
}

const openMemory = (memory: Memory) => {
  emit('selectMemory', memory.name)
}

/** Human-readable byte size (1 KB = 1024 bytes). */
const formatSize = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

onMounted(() => {
  loadMemories()
})

defineExpose({
  refresh: loadMemories,
})
</script>

<template>
  <div class="memory-list">
    <!-- Loading State — skeleton holds the card list's height instead of
         collapsing the panel to one centered row. -->
    <ListSkeleton v-if="isLoading" :rows="5" row-height="h-16" test-id="memory-list-skeleton" />

    <!-- Error State -->
    <div v-else-if="error" class="text-center py-8">
      <p class="text-body" style="color: var(--color-red);">{{ error }}</p>
      <button
        @click="loadMemories"
        class="mt-3 px-4 py-2 rounded-lg text-body transition-colors duration-200"
        style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
      >
        Retry
      </button>
    </div>

    <!-- Empty State -->
    <div v-else-if="memories.length === 0" class="text-center py-8">
      <p class="text-body" style="color: var(--semantic-text-muted);">No memories yet</p>
    </div>

    <!-- Memory List -->
    <div v-else class="space-y-2">
      <div
        v-for="mem in memories"
        :key="mem.name"
        class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90"
        :class="{ 'ring-2': props.selectedMemoryName === mem.name }"
        :style="props.selectedMemoryName === mem.name
          ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);'
          : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
        @click="openMemory(mem)"
      >
        <div class="flex items-start gap-3">
          <UiIcon name="brain" class="w-5 h-5 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h3 class="text-body font-medium truncate" style="color: var(--semantic-text);">
              {{ mem.title }}
            </h3>
            <p class="text-dense mt-1 truncate" style="color: var(--semantic-text-muted);">
              {{ mem.name }}
            </p>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim);">
              {{ formatSize(mem.size) }}
            </p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
