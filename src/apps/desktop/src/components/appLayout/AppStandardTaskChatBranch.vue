<script setup lang="ts">
import StandardTaskChatView from '../views/StandardTaskChatView.vue'
import type { Task } from '../../stores/workspaces'

defineProps<{ task: Task; cwd: string }>()
const emit = defineEmits<{ 'update-chat-id': [oldId: string, newId: string]; close: [] }>()
</script>

<template>
  <!--
    Standard task chat (folder / memory / chat items — anything
    that isn't a kanban, design, OR agent). FIX for blank
    chatview (task_1787027750097, 2026-08-14): the
    simplify-url-browser plan (#246) wired the kanban chat
    and design (DesignChatDialog) chat-open
    paths but listed "folder tasks … out-of-scope edge case".
    A user with a chat task on a folder / memory / chat
    workspace item hit a dead zone: setActiveTask fires,
    clears activeChatId, and NONE of the v-else-if branches
    above matched — right pane was blank.

    Render <StandardTaskChatView> with the active task —
    encapsulates the chat-id / chat-name / :key wiring (see
    StandardTaskChatView.vue). The wrapper passes the task id
    as the chat session id (migration 052 invariant: task.id
    == session.id) and forwards :cwd so sendChatMessage writes
    the right cwd_session. We pass props explicitly rather
    than going through navigationStore so this branch doesn't
    fight the activeTask state the kanban + design branches
    depend on.

    `@close` routes ChatView's app-bar ✕ through
    handleCloseTaskView, the same handler the kanban and agent
    branches use. With `:show-header` set on the wrapper, this mode
    renders the same shared ChatAppBar as the other two, so the
    title / ◫ / ✕ sit in the same place in all three.

    Mount order matters: this v-else-if is AFTER AgentView
    (above), so 'agent' items render AgentView not ChatView.
    It precedes the standalone `<ChatView v-else-if=
    "activeChatId.startsWith('chat-')">` branch below, so a
    folder task lands here even when activeChatId is empty
    (cleared by setActiveTask).
  -->
  <StandardTaskChatView
    :task="task"
    :cwd="cwd"
    @update-chat-id="(oldId, newId) => emit('update-chat-id', oldId, newId)"
    @close="emit('close')"
  />
</template>
