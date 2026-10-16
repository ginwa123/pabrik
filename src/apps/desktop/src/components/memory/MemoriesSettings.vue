<script setup lang="ts">
import { ref } from 'vue'
import MemoryList from '../tool_outputs/MemoryList.vue'
import MemoryDetail from './MemoryDetail.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const selectedMemoryName = ref<string | null>(null)
const memoryListRef = ref<InstanceType<typeof MemoryList> | null>(null)
const memoryDetailRef = ref<InstanceType<typeof MemoryDetail> | null>(null)

const handleSelectMemory = (name: string) => {
  selectedMemoryName.value = name
}

/** Open the create-mode form in the right panel. Wired to the "+ New Memory" button in the list
 * header so the user doesn't have to first deselect the current memory. */
const handleCreateClick = () => {
  selectedMemoryName.value = null
  memoryDetailRef.value?.startCreate()
}

const handleMemoryDeleted = (): void => {
  selectedMemoryName.value = null
  memoryListRef.value?.refresh()
  emit('notification', 'Memory deleted successfully', 'success')
}

const handleMemorySaved = () => {
  memoryListRef.value?.refresh()
  emit('notification', 'Memory saved', 'success')
}

const handleError = (message: string) => {
  emit('notification', message, 'error')
}
</script>

<template>
  <div class="flex h-full gap-6">
    <!-- Memory List Panel -->
    <div class="w-80 shrink-0 flex flex-col overflow-hidden">
      <div
        class="rounded-xl p-6 flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-start justify-between gap-2 mb-4 shrink-0">
          <h2
            class="text-lead font-semibold"
            style="color: var(--semantic-text);"
          >Memories</h2>
          <button
            @click="handleCreateClick"
            class="px-3 py-1 text-dense rounded font-medium shrink-0"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            title="Create a new memory"
          >
            + New Memory
          </button>
        </div>
        <p class="text-body mb-4 shrink-0" style="color: var(--semantic-text-muted);">
          Global markdown notes the agent can reference. Files live in <code>~/.config/pabrik/memories/</code>.
        </p>
        <div class="flex-1 overflow-y-auto min-h-0">
          <MemoryList
            ref="memoryListRef"
            :selected-memory-name="selectedMemoryName"
            @select-memory="handleSelectMemory"
          />
        </div>
      </div>
    </div>

    <!-- Memory Detail Panel -->
    <div class="flex-1 flex flex-col overflow-hidden">
      <div
        class="rounded-xl flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <h2
          class="text-lead font-semibold p-4 shrink-0"
          style="color: var(--semantic-text); border-bottom: 1px solid var(--color-border);"
        >Memory</h2>
        <div class="flex-1 overflow-hidden">
          <MemoryDetail
            :memory-name="selectedMemoryName"
            @memory-deleted="handleMemoryDeleted"
            @memory-saved="handleMemorySaved"
            @error="handleError"
          />
        </div>
      </div>
    </div>
  </div>
</template>
