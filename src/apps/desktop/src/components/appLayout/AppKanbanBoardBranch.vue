<script setup lang="ts">
import KanbanView from '../kanban/KanbanView.vue'
import type { WorkspaceItem } from '../../stores/workspaces'

defineProps<{ item: WorkspaceItem; workspaceId: string }>()
</script>

<template>
  <!-- Kanban view (kanban-embed-chatview plan, Task 5). The kanban
       now owns the chat pane + resize handle internally — the old
       3-column sibling-of-KanbanView branch (was at lines
       1716-1814) is GONE. KanbanView renders the full-width board
       when no task is active (the kanban chat branch above claims the
       task-active case). The :key on
       KanbanView forces a fresh mount when the user navigates
       from one kanban to another (KanbanView fetches columns on
       mount). `@close-chat` fires when ChatView's close button is
       clicked — AppLayout handles URL routing + state cleanup. -->
  <KanbanView :item="item" :workspace-id="workspaceId" :item-id="item.id" />
</template>
