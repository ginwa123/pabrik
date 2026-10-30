<script setup lang="ts">
import FilePickerDialog from '../FilePickerDialog.vue'
import KanbanPrList from './KanbanPrList.vue'
import KanbanTaskDetail from './KanbanTaskDetail.vue'
import { useKanbanBoardContext } from './kanbanBoardContext'

const {
  activeCreateColumn,
  activeCreateColumnId,
  activeTaskDetail,
  activeTaskDetailColumn,
  closePrList,
  createBusy,
  createError,
  handleCreateTaskSave,
  handleProjectRootSelected,
  handleStartAgent,
  handleTaskDetailSave,
  handleUnattendedToggle,
  handleUpdateCwd,
  item,
  itemId,
  loadItemsForPathPicker,
  onDetailShowUpdate,
  onCreateShowUpdate,
  onPrListClosed,
  onPrListOpenCount,
  onPrTabChange,
  prsOpen,
  prsTab,
  setPrListEl,
  showCreateDialog,
  showPathPicker,
  showTaskDetail,
  sortedColumns,
  startAgentError,
  tasks,
  workspaceId,
} = useKanbanBoardContext()
</script>

<template>
    <!--
    Full-cover task view (replaces the former centered card AND the
    old KanbanTaskDetailDialog modal). Covers the whole kanban view
    area like the task chat does — the board stays mounted
    underneath but is fully hidden. Opening appends
    ?detail=<taskId> via router.push, so browser Back drops the
    param and the route guard returns to the plain board. Close
    via the panel's X / Cancel / Esc, Save, or Back. Edit + create
    are mutually exclusive.
  -->
    <div
      v-if="showTaskDetail || showCreateDialog"
      class="absolute inset-0 z-30 overflow-hidden"
      style="background-color: var(--semantic-content-bg)"
      data-testid="kanban-detail-panel"
    >
      <div class="flex h-full w-full flex-col p-3 sm:p-4">
        <KanbanTaskDetail
          v-if="showTaskDetail"
          :show="showTaskDetail"
          @update:show="onDetailShowUpdate"
          :task="activeTaskDetail"
          :column="activeTaskDetailColumn"
          :cwd="item.path || ''"
          :workspace-id="workspaceId"
          :error-message="startAgentError"
          :tasks="tasks"
          @save="handleTaskDetailSave"
          @update-unattended="handleUnattendedToggle"
          @update-cwd="handleUpdateCwd"
          @start-agent="handleStartAgent"
        />
        <KanbanTaskDetail
          v-if="showCreateDialog"
          :show="showCreateDialog"
          @update:show="onCreateShowUpdate"
          mode="create"
          :task="null"
          :column="activeCreateColumn"
          :available-columns="sortedColumns"
          :cwd="item.path || ''"
          :workspace-id="workspaceId"
          :error-message="createError"
          :creating="createBusy"
          @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_session' })"
          @create-and-run="
            (payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })
          "
          @column-change="(columnId) => (activeCreateColumnId = columnId)"
        />
      </div>
    </div>
    <!--
    Full-cover change-request list (kanban-pull-request-button).
    Mounted like the task detail panel above: a `v-if` full-cover
    block that hides the board underneath. `?prs=` in the URL is the
    source of truth (Back drops the param, the route guard closes
    this locally). No `data-testid` on this wrapper — the component
    root already carries `kanban-pr-list-panel`.
  -->
    <div
      v-if="prsOpen"
      class="absolute inset-0 z-30 overflow-y-auto"
      style="background-color: var(--semantic-card-bg)"
    >
      <KanbanPrList
        :ref="setPrListEl"
        :item-path="item.path || ''"
        :item-id="itemId || item.id"
        :workspace-id="workspaceId"
        :tasks="tasks"
        :open="prsOpen"
        :tab="prsTab"
        @back="closePrList"
        @tab-change="onPrTabChange"
        @open-count="onPrListOpenCount"
        @closed="onPrListClosed"
      />
    </div>
  <!--
    FilePickerDialog for the "Set project root" banner. Mounted at the
    bottom of the template so it sits in the same Teleport target as
    the rest of the kanban's modals. Same data source wiring as
    AddKanbanDialog's picker — kept duplicated (not extracted) to
    avoid coupling the two pickers.
  -->
  <FilePickerDialog
    v-model="showPathPicker"
    mode="folder"
    :load-items="loadItemsForPathPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="false"
    :enable-recent-history="true"
    title="Select Project Root for this Kanban"
    @select="handleProjectRootSelected"
  />
</template>
