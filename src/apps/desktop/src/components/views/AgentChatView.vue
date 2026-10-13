<!--
  AgentChatView — inline chat view for agent sessions.

  Replaces the former AgentChatDialog modal overlay. Renders inline
  (no Teleport, no backdrop, no show prop) so the agent chat lives
  in the normal layout flow, mirroring StandardTaskChatView.

  App bar
  ───────
  This component used to hand-roll its own header — `px-5 py-3`, a
  text "✕ Close" button, no sidebar toggle, spanning the full window
  width ABOVE the right sidebar. That made agent mode look nothing
  like kanban mode (a `h-11` bar with a `◫` toggle beside the
  sidebar) or folder mode (no bar at all). It now delegates to the
  shared ChatAppBar by forwarding `:show-header` to the inner
  ChatView and re-emitting its `close`, so all three workspace-item
  modes render the identical bar. The per-session busy spinner
  rides along in ChatView's `app-bar-extras` slot.

  Public API:
    props:  task, workspaceId, itemId, cwd
    emits:  close
-->
<script setup lang="ts">
import ChatView from './ChatView.vue'
import SessionSlider from '../SessionSlider.vue'

interface Props {
  task: { id: string; name?: string; task_type?: string }
  workspaceId: string
  itemId: string
  cwd: string
}

const props = defineProps<Props>()
const emit = defineEmits<{ close: [] }>()
</script>

<template>
  <!-- Wrapper bg must match AppLayout's main-content (--semantic-content-bg, #181616),
       not --semantic-card-bg (#1D1C19), or agent chats render a warmer/lighter
       shade than standalone + design chats. -->
  <div
    class="w-full h-full flex flex-col overflow-hidden"
    style="background-color: var(--semantic-content-bg)"
    data-testid="agent-chat-view"
  >
    <ChatView
      :key="'agent-chat-' + props.task.id"
      :chat-id="props.task.id"
      :chat-name="props.task.name || 'Agent Chat'"
      type="task"
      :cwd="props.cwd"
      :show-header="true"
      @close="emit('close')"
    >
      <!-- Same per-session worker indicator the sidebar/task rows show:
           a yellow circle spinner while
           processingState[task.id] is true. The key matches the inner
           ChatView's session id (it strips a leading `chat-`, and we
           pass the raw task id, so both resolve to task.id). -->
      <template #app-bar-extras>
        <SessionSlider :session-id="props.task.id" test-id="agent-chat-slider" />
      </template>
    </ChatView>
  </div>
</template>
