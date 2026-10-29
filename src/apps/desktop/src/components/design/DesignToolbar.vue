<script setup lang="ts">
import UiIcon from '../ui/UiIcon.vue'
import type { DesignPage } from '../../api'

const props = defineProps<{ itemName: string; page: DesignPage | null }>()

const emit = defineEmits<{
  openChat: [payload: { pageId: string; pageName: string; workspaceItemTaskId: string }]
}>()

const openChat = (): void => {
  emit('openChat', {
    pageId: props.page?.id ?? '',
    pageName: props.page?.name ?? '',
    workspaceItemTaskId: props.page?.workspace_item_task_id ?? '',
  })
}
</script>

<template>
  <!--
    NEW (2026-07-14): Top-level action bar. Always renders
    regardless of pages state (loading / error / empty / canvas)
    so the chat toggle is reachable even before the user has
    added a page — the primary flow is "ask the LLM to draw me
    a login form" via the chat, then the page appears. Without
    this top-level bar, the chat toggle was buried inside the
    canvas header which only renders when pages.length > 0, so
    the empty state had no chat access (the bug the user
    reported on 2026-07-14).

    Layout: [item name | flex spacer | 💬 Chat button]. The
    item name is small + dim so it doesn't compete with the
    page tabs for attention; the chat button is the only
    always-visible action.
  -->
  <div
    class="px-3 py-2 flex items-center gap-3 shrink-0"
    style="
      border-bottom: 1px solid var(--color-border);
      background-color: var(--semantic-sidebar-bg);
    "
    data-testid="design-toolbar"
  >
    <div
      class="text-dense font-medium truncate"
      style="color: var(--semantic-text-dim)"
      :title="itemName"
    >
      {{ itemName }}
    </div>
    <div class="flex-1" />
    <button
      type="button"
      class="px-2.5 py-1 rounded text-dense font-medium flex items-center gap-1.5 transition-opacity duration-150 hover:opacity-100"
      style="
        background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
        color: var(--color-bg);
      "
      data-testid="design-open-chat-button"
      aria-label="Open design chat"
      title="Open design chat"
      @click="openChat"
    >
      <UiIcon name="chat" />
      <span>Chat</span>
    </button>
  </div>
</template>
