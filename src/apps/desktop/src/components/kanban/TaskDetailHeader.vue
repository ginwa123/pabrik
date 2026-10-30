<script setup lang="ts">
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const { isCreateMode, handleClose } = useTaskDetailContext()
</script>

<template>
    <div
      class="px-5 pt-5 pb-4 shrink-0 sticky top-0 z-10"
      style="
        border-bottom: 1px solid var(--color-border);
        background-color: var(--semantic-card-bg);
      "
    >
      <div class="flex items-start justify-between gap-3">
        <h3
          :id="isCreateMode ? 'kanban-task-detail-create-title' : 'kanban-task-detail-title'"
          class="text-title font-semibold truncate"
          style="color: var(--semantic-text)"
        >
          {{ isCreateMode ? 'New task' : 'Task details' }}
        </h3>
        <button
          type="button"
          @click="handleClose"
          data-testid="kanban-task-detail-close"
          class="w-8 h-8 rounded-lg flex items-center justify-center shrink-0 transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-muted)"
          title="Close"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </div>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        {{
          isCreateMode
            ? 'Create a new task, or start an agent on it right away.'
            : 'Edit name, description, and tags. Changes save on click.'
        }}
      </p>
    </div>
</template>
