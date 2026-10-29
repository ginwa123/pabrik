<script setup lang="ts">
import ChatView from '../views/ChatView.vue'

defineProps<{ chatId: string; chatName: string; cwd: string }>()
const emit = defineEmits<{ 'update-chat-id': [oldId: string, newId: string]; close: [] }>()
</script>

<template>
  <!-- Standalone chat (sidebar-opened `chat-<id>` sessions, no task).
       Renders the same shared ChatAppBar as the kanban / agent /
       standard branches above, so the title / ◫ / ✕ sit in the
       same place in every mode. `@close` reuses handleCloseTaskView,
       which clears both the task and the chat. -->
  <ChatView
    :chat-id="chatId"
    :chat-name="chatName"
    :cwd="cwd"
    :show-header="true"
    @update-chat-id="(oldId, newId) => emit('update-chat-id', oldId, newId)"
    @close="emit('close')"
  />
</template>
