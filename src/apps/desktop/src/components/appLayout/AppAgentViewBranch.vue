<script setup lang="ts">
import AgentView from '../views/AgentView.vue'
import type { AgnosticKnowledgeRow, AgnosticSystemPromptRow } from '../views/AgentView.vue'
import type { WorkspaceItem } from '../../stores/workspaces'

defineProps<{
  item: WorkspaceItem
  workspaceId: string
  knowledge: AgnosticKnowledgeRow[]
  tools: string[]
  systemPrompts: AgnosticSystemPromptRow[]
  parentLoading: boolean
}>()
</script>

<template>
  <!-- Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
       4th workspace-item type. Mounted when item_type='agent'
       and NO chat task is open (the AgentChatView branch above
       wins when a task is active). The view is responsible for
       fetching its own agent data (knowledge + tools) via
       /api/workspaces/:wsId/items/:itemId/agent.
       IMPORTANT: this v-else-if must come BEFORE the new
       standard-task ChatView below (origin/main's blank-chatview
       fix) so 'agent' items render AgentView, not a plain
       ChatView. The new ChatView's v-else-if condition
       (`item_type !== 'kanban' && !== 'design'`) WOULD match
       'agent' items, so order matters. -->
  <AgentView
    :item="item"
    :workspace-id="workspaceId"
    :item-id="item.id"
    :knowledge="knowledge"
    :tools="tools"
    :system-prompts="systemPrompts"
    :parent-loading="parentLoading"
  />
</template>
