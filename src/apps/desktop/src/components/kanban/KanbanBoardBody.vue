<script setup lang="ts">
import KanbanColumn from './KanbanColumn.vue'
import KanbanRowView from './KanbanRowView.vue'
import { useKanbanBoardContext } from './kanbanBoardContext'

const {
  collapsedColumnIds,
  emit,
  handleColumnSortChange,
  handleRunAgentFromMenu,
  handleRunAllAgents,
  handleStopAllAgents,
  handleViewTaskDetail,
  item,
  itemId,
  layout,
  prColumnKey,
  rowDensity,
  runAllBusyByColumn,
  setColumnRef,
  setColumnsContainerEl,
  setRowsContainerEl,
  sortedColumns,
  stopAllBusyByColumn,
  tasks,
  toggleColumnCollapsed,
  workspaceId,
} = useKanbanBoardContext()
</script>

<template>
      <!-- ─── Columns row (horizontal scroll) ──────────────────────────── -->
      <!--
      Horizontal scroll position is persisted to localStorage so the
      kanban stays where the user scrolled it across the standalone
      <-> 3-column layout transition in AppLayout. See
      useKanbanScrollRestore composable + the comment block in the
      <script setup>. Do NOT remove `ref="kanbanColumnsContainer"`
      without also removing the composable call — the two are paired.
    -->
      <div
        v-if="layout === 'columns'"
        :ref="setColumnsContainerEl"
        class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden"
        style="scrollbar-width: thin"
        :data-testid="`kanban-view-${item.id}-columns`"
      >
        <div class="flex gap-3 p-3 h-full items-stretch">
          <KanbanColumn
            v-for="column in sortedColumns"
            :key="prColumnKey(column.id)"
            :ref="setColumnRef(column.id)"
            :column="column"
            :tasks="tasks"
            :workspace-id="workspaceId"
            :item-id="itemId || item.id"
            :cwd="item.path || ''"
            :columns="sortedColumns"
            @move-task="(payload) => emit('moveTask', payload)"
            @rename-column="(payload) => emit('renameColumn', payload)"
            @delete-column="(columnId) => emit('deleteColumn', columnId)"
            @reorder-column="(payload) => emit('reorderColumn', payload)"
            @request-rename-column="(columnId) => emit('requestRenameColumn', columnId)"
            @request-delete-column="(columnId) => emit('requestDeleteColumn', columnId)"
            @request-run-all-agents="handleRunAllAgents"
            @run-agent="(payload) => handleRunAgentFromMenu(payload)"
            :run-all-busy="!!runAllBusyByColumn[column.id]"
            :stop-all-busy="!!stopAllBusyByColumn[column.id]"
            @request-stop-all-agents="handleStopAllAgents"
            @select-task="(id) => emit('selectTask', id)"
            @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
            @open-task-detail-in-background="
              (payload) => emit('openTaskDetailInBackground', payload)
            "
            @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
            @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
            @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
            @view-task-detail="handleViewTaskDetail"
            @sort-change="(payload) => handleColumnSortChange(column.id, payload)"
          />
        </div>
      </div>

      <!-- Row mode — the same board as a grouped linear list. Shares the
           header, banners, detail panel and search with column mode; only
           this body differs. The wrapper div owns the vertical scroll
           container ref (a ref on a component yields the instance, not
           the element). -->
      <div v-else :ref="setRowsContainerEl" class="flex-1 min-h-0 flex flex-col">
        <KanbanRowView
          :columns="sortedColumns"
          :tasks="tasks"
          :workspace-id="workspaceId"
          :item-id="itemId || item.id"
          :cwd="item.path || ''"
          :collapsed-ids="collapsedColumnIds"
          :density="rowDensity"
          :run-all-busy-by-column="runAllBusyByColumn"
          :stop-all-busy-by-column="stopAllBusyByColumn"
          @toggle-collapse="toggleColumnCollapsed"
          @rename-column="(payload) => emit('renameColumn', payload)"
          @delete-column="(columnId) => emit('deleteColumn', columnId)"
          @request-rename-column="(columnId) => emit('requestRenameColumn', columnId)"
          @request-delete-column="(columnId) => emit('requestDeleteColumn', columnId)"
          @request-run-all-agents="handleRunAllAgents"
          @request-stop-all-agents="handleStopAllAgents"
          @select-task="(id) => emit('selectTask', id)"
          @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
          @open-task-detail-in-background="(payload) => emit('openTaskDetailInBackground', payload)"
          @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
          @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
          @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
          @view-task-detail="handleViewTaskDetail"
          @run-agent="(payload) => handleRunAgentFromMenu(payload)"
          @sort-change="(payload) => handleColumnSortChange(payload.columnId, payload)"
        />
      </div>
</template>
