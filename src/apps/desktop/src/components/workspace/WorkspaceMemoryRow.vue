<script setup lang="ts">
import { computed } from 'vue'
import { formatRelativeTime } from '../../helpers/relativeTime'
import type { WorkspaceMemory } from '../../api'

const props = defineProps<{
  memory: WorkspaceMemory
  expanded: boolean
  deleting: boolean
}>()

const emit = defineEmits<{
  toggle: []
  delete: []
}>()

const preview = computed(() => {
  const firstLine =
    props.memory.content.split('\n').find((line) => line.trim().length > 0) ?? props.memory.content
  return firstLine.length > 160 ? `${firstLine.slice(0, 160)}…` : firstLine
})

const updatedLabel = computed(() => {
  const relative = formatRelativeTime(props.memory.updated_at)
  return relative === 'now' ? 'updated just now' : `updated ${relative} ago`
})
</script>

<template>
  <li
    class="rounded-md overflow-hidden"
    style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    :data-testid="`workspace-memories-row-${memory.id}`"
  >
    <button
      type="button"
      class="w-full text-left px-4 py-3 transition-colors duration-150"
      style="background-color: transparent"
      :aria-expanded="expanded"
      @click="emit('toggle')"
    >
      <p
        class="text-body leading-relaxed"
        :class="expanded ? 'whitespace-pre-wrap' : 'truncate'"
        style="color: var(--semantic-text)"
      >
        {{ expanded ? memory.content : preview }}
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-2">
        <span
          v-for="tag in memory.tags"
          :key="tag"
          class="text-micro px-1.5 py-0.5 rounded"
          style="background-color: var(--semantic-wash); color: var(--semantic-text-muted)"
          >{{ tag }}</span
        >
        <span class="text-dense" style="color: var(--semantic-text-dim)">{{ updatedLabel }}</span>
      </div>
    </button>

    <div
      v-if="expanded"
      class="px-4 pb-3 flex items-center justify-between gap-3"
      style="border-top: 1px solid var(--color-border)"
    >
      <p class="text-dense pt-2" style="color: var(--semantic-text-dim)">
        <span class="font-mono">{{ memory.id }}</span> · created {{ memory.created_at }} · updated
        {{ memory.updated_at }}
      </p>
      <button
        type="button"
        class="mt-2 px-3 h-7 rounded-md text-dense shrink-0 transition-colors duration-150 disabled:opacity-50"
        style="background-color: var(--tint-error); color: var(--color-red)"
        :disabled="deleting"
        :data-testid="`workspace-memories-delete-${memory.id}`"
        @click="emit('delete')"
      >
        {{ deleting ? 'Deleting…' : 'Delete' }}
      </button>
    </div>
  </li>
</template>
