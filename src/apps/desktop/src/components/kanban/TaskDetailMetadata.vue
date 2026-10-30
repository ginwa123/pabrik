<script setup lang="ts">
import { computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  columnLabel,
  isColumnPickerOpen,
  isCreateMode,
  props,
  selectColumn,
  selectedColumnId,
  setColumnPickerEl,
  taskTypeLabel,
  toggleColumnPicker,
} = useTaskDetailContext()

const task = computed(() => props.task)
</script>

<template>
          <div
            v-if="columnLabel || (!isCreateMode && (taskTypeLabel || task?.is_pinned))"
            class="ktd-rail-group"
            data-testid="kanban-task-detail-metadata"
          >
            <div v-if="isCreateMode && props.availableColumns.length > 0" :ref="setColumnPickerEl">
              <span class="ktd-rail-label">Column</span>
              <button
                type="button"
                @click.stop="toggleColumnPicker"
                class="ktd-picker w-full min-w-[180px] justify-between flex items-center gap-1.5"
                data-testid="kanban-task-detail-column-picker"
              >
                <span class="inline-flex items-center gap-1.5">
                  <UiIcon name="clipboard" />
                  <span class="font-medium">{{ columnLabel }}</span>
                </span>
                <span class="text-micro" style="color: var(--semantic-text-muted)">▾</span>
              </button>
              <div
                v-if="isColumnPickerOpen"
                class="ktd-list mt-1"
                data-testid="kanban-task-detail-column-picker-dropdown"
                @click.stop
              >
                <button
                  v-for="col in props.availableColumns"
                  :key="col.id"
                  type="button"
                  @click="selectColumn(col.id)"
                  class="ktd-list-row w-full text-left text-dense flex items-center justify-between"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-task-detail-column-picker-item-${col.id}`"
                >
                  <span class="font-medium">{{ col.name }}</span>
                  <span v-if="selectedColumnId === col.id">✓</span>
                </button>
              </div>
            </div>
            <div v-else-if="columnLabel">
              <span class="ktd-rail-label">Column</span>
              <span
                data-testid="kanban-task-detail-column"
                class="ktd-picker w-full inline-flex items-center gap-1.5"
              >
                <UiIcon name="clipboard" />
                {{ columnLabel }}
              </span>
            </div>
            <div
              v-if="!isCreateMode && (taskTypeLabel || task?.is_pinned)"
              class="flex flex-wrap items-center gap-1.5 mt-2"
            >
              <span v-if="taskTypeLabel" data-testid="kanban-task-detail-type" class="ktd-chip">
                {{ taskTypeLabel }}
              </span>
              <span v-if="task?.is_pinned" data-testid="kanban-task-detail-pinned" class="ktd-chip">
                <UiIcon name="pin" />
                Pinned
              </span>
            </div>
          </div>
</template>

<style scoped>
.ktd-rail-group {
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
}


.ktd-rail-label {
  display: block;
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--semantic-text-muted);
  margin-bottom: 5px;
}


.ktd-picker {
  min-height: 30px;
  padding: 5px 8px;
  border-radius: 6px;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
}


.ktd-list {
  border-radius: 8px;
  overflow: hidden;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
}


.ktd-list-row {
  padding: 7px 10px;
  border-top: 1px solid var(--color-border);
}


.ktd-list-row:first-child {
  border-top: 0;
}


.ktd-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  border-radius: 6px;
  font-size: var(--text-dense);
  font-weight: 500;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text-muted);
}
</style>
