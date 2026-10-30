<script setup lang="ts">
import AgentChatView from '../views/AgentChatView.vue'
import type { Task } from '../../stores/workspaces'

defineProps<{ task: Task; workspaceId: string; itemId: string; cwd: string }>()
const emit = defineEmits<{ close: [] }>()
</script>

<template>
  <!-- Agent chat (inline, non-dialog): when a chat task is open
       under an agent item, the chat REPLACES the AgentView config
       below (same swap semantics as StandardTaskChatView for
       folder tasks). MUST be v-else-if in this chain and placed
       BEFORE AgentView — a standalone v-if would start a new
       chain and render BOTH stacked (config on top, chat
       squeezed at the bottom). Closing the chat (@close →
       handleCloseTaskView clears activeTask) falls back to
       AgentView. AgentChatView no longer hand-rolls a header — it
       forwards `:show-header` + `@close` to its inner ChatView, so
       agent mode renders the same shared ChatAppBar as the kanban
       and standard branches. -->
  <AgentChatView
    :task="task"
    :workspace-id="workspaceId"
    :item-id="itemId"
    :cwd="cwd"
    @close="emit('close')"
  />
</template>
