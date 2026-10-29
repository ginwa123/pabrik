<script setup lang="ts">
import DesignView from '../design/DesignView.vue'
import type { WorkspaceItem } from '../../stores/workspaces'

defineProps<{ item: WorkspaceItem; workspaceId: string }>()
</script>

<template>
  <!-- Design view (Chunk 8 of design-mode-redesign). Mirrors the
       single-column kanban branch above: full-bleed render when
       a design workspace item is active and no chat is open.
       The :key forces a fresh mount on item switch so the page
       list re-fetches. DesignView emits page/element mutations
       which we forward to the workspaces store (or api layer
       directly for page create — no store action yet).

       2026-08-06 (plan: design-chat-as-dialog): the design chat
       no longer shares this branch with a side-by-side chat
       column. The previous 3-column [DesignView | resize-handle |
       ChatView] layout (added in commit d0a05eb0, 2026-07-14)
       took ~40-65% of the canvas for ChatView even when
       "minimised". The chat is now a centred modal dialog
       (DesignChatDialog) mounted at the AppLayout level above —
       the canvas stays full-width behind a dimmed+blurred
       backdrop. The pre-fix data-design-three-column branch,
       data-design-resize-handle, design-chat-collapse-button,
       and design-chat-expand-button are GONE with the resize /
       collapse state machine. -->
  <DesignView :item="item" :workspace-id="workspaceId" :item-id="item.id" />
</template>
