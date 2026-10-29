<script setup lang="ts">
import ChatView from '../views/ChatView.vue'
import type { Task } from '../../stores/workspaces'

defineProps<{ task: Task; cwd: string }>()
const emit = defineEmits<{ 'update-chat-id': [oldId: string, newId: string]; close: [] }>()
</script>

<template>
  <!-- Kanban task chat (inline view, own tab). When a chat task that
       belongs to THIS kanban item is active, the chat is the main
       surface. It MUST be a v-else-if in this chain and placed BEFORE
       the KanbanView branch below — the KanbanView branch only tests
       `item_type === 'kanban'`, so it would otherwise win the chain and
       the chat would never render; and a standalone v-if here would
       start a NEW chain and stack board + chat.

       The chat tab (URL `itemId=I/chat/<taskId>`) and the board tab
       (bare `itemId=I`) carry different tab keys, so this one branch
       gives each tab its own body with no extra state. `:key` forces a
       fresh mount per task, preserving useChatScrollRestore's
       per-session scroll contract when the user switches cards.
       `:show-header` renders the shared ChatAppBar (title + ◫ + ✕) so
       the chat stays closable with tab mode off; the ✕ routes through
       handleCloseTaskView, which closes the tab when one owns the chat.
       The other two task-chat modes (AgentChatView below,
       StandardTaskChatView further down) set the same flag, so all
       three render the identical bar. -->
  <ChatView
    :chat-id="task.id"
    :chat-name="task.name ?? ''"
    :type="'task'"
    :cwd="cwd"
    :show-header="true"
    @update-chat-id="(oldId, newId) => emit('update-chat-id', oldId, newId)"
    @close="emit('close')"
  />
</template>
