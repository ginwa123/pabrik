<script setup lang="ts">
import AddDesignElementDialog from './AddDesignElementDialog.vue'
import DesignContextMenu from './DesignContextMenu.vue'
import MoveToPageDialog from './MoveToPageDialog.vue'
import type { DesignElement as DesignElementApi, DesignPage } from '../../api'
import type { ContextMenuState } from '../../composables/useDesignContextMenu'

defineProps<{
  showAddElementDialog: boolean
  activePageId: string
  elements: DesignElementApi[]
  menu: ContextMenuState
  moveToPageVisible: boolean
  elementName: string
  pages: DesignPage[]
}>()

const emit = defineEmits<{
  create: [body: { name: string; type: DesignElementApi['type']; html: string }]
  closeAddElement: []
  group: [targetIds: string[]]
  ungroup: [elementId: string]
  leaveGroup: [elementId: string]
  selectAll: []
  moveToPage: [elementId: string]
  bringToFront: []
  bringForward: []
  sendBackward: []
  sendToBack: []
  contextMenuDelete: [targetIds: string[]]
  closeMenu: []
  moveToPageClose: []
  moveToPageSelect: [newPageId: string]
}>()
</script>

<template>
  <!-- ─── Add element dialog ───────────────────────────────────── -->
  <AddDesignElementDialog
    :show="showAddElementDialog"
    :page-id="activePageId"
    :readonly="false"
    @create="emit('create', $event)"
    @close="emit('closeAddElement')"
  />

  <!-- ─── Canvas right-click context menu (Chunk 3+5+9) ────────────
       Disabled in Preview mode (the canvasContextMenu composable
       keeps `visible: false` because handleCanvasContextMenu
       short-circuits there). -->
  <DesignContextMenu
    :visible="menu.visible"
    :x="menu.x"
    :y="menu.y"
    :target-ids="menu.targetIds"
    :elements="elements"
    @group="emit('group', $event)"
    @ungroup="emit('ungroup', $event)"
    @leave-group="emit('leaveGroup', $event)"
    @select-all="emit('selectAll')"
    @move-to-page="emit('moveToPage', $event)"
    @bring-to-front="emit('bringToFront')"
    @bring-forward="emit('bringForward')"
    @send-backward="emit('sendBackward')"
    @send-to-back="emit('sendToBack')"
    @delete="emit('contextMenuDelete', $event)"
    @close="emit('closeMenu')"
  />

  <!-- NEW (2026-08-06, design-move-to-page plan, Chunk 8): centred
       modal for choosing the target page when the user clicks
       "Move to page..." in the right-click menu. Mounted at the
       AppLayout-equivalent level so it escapes the canvas's
       transform/overflow contexts.
       Pages list comes from workspacesStore.designPagesByItemId
       (single source of truth shared with the sidebar tree). -->
  <MoveToPageDialog
    :visible="moveToPageVisible"
    :element-name="elementName"
    :current-page-id="activePageId"
    :pages="pages"
    @close="emit('moveToPageClose')"
    @select="emit('moveToPageSelect', $event)"
  />
</template>
