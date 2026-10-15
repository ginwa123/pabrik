<!--
  DesignContextMenu — shared right-click menu for the design canvas
  and layers panel. Full 7-item table per the right-click group menu
  plan (Chunk 5).

  Items (in display order):
    1. Group selection      (Cmd+G)
    2. Leave group          (no shortcut — drag-out affordance only)
    3. Ungroup              (Cmd+Shift+G)
    4. Select all           (Cmd+A)
    ─── separator
    5. Bring to front       (Cmd+Shift+])
    6. Bring forward        (Cmd+])
    7. Send backward        (Cmd+[)
    8. Send to back         (Cmd+Shift+[)
    ─── separator
    9. Delete               (Backspace)

  Leave group is the inverse of the drag-to-join-group affordance
  (PR #151). It pulls the SINGLE selected element out of its current
  parent group/frame to top-level — the group itself is preserved
  (other children stay nested). Distinct from Ungroup, which
  *dissolves* the selected group/frame and reparents ITS children to
  the group's parent.

  Why Teleport to body: the menu must float above the design canvas
  (which has `transform: scale()` for zoom + `overflow: auto`). A
  plain div child of either parent would be clipped by the canvas's
  overflow. Teleporting to body escapes the stacking context.

  Pattern reference: src/apps/desktop/src/components/git/GitChanges.vue
  uses the same Teleport approach for the git file context menu.

  Edge clamping: if the menu would overflow the right or bottom of the
  viewport, shift it left/up so its right/bottom edge sits 8px inside
  the viewport. Estimated dimensions: 220px wide, 40px per item.
-->
<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  visible: boolean
  x: number
  y: number
  targetIds: string[]
  /** The full element list for the active page. Used to determine
   * whether the current `targetIds` selection contains exactly one
   * group/frame (the only state in which Ungroup can fire —
   * matches Figma: Ungroup is greyed out unless the single selection
   * is a group), and whether the single selection has a `parent_id`
   * set (the only state in which Leave group can fire — matches
   * Figma: "Pull out of group" is greyed out for top-level elements). */
  // `parent_id` accepts the same shape the API returns: a non-empty
  // string means the element is currently inside a group/frame;
  // empty string (`COALESCE(parent_id, '')`) or null/undefined means
  // top-level. The canLeaveGroup computed treats empty/null/
  // undefined the same way (no parent → button is disabled).
  elements: ReadonlyArray<{ id: string; type: string; parent_id?: string | null }>
}>()

const emit = defineEmits<{
  close: []
  group: [targetIds: string[]]
  leaveGroup: [targetId: string]
  ungroup: [targetId: string]
  moveToPage: [targetId: string]
  selectAll: []
  bringToFront: [targetIds: string[]]
  bringForward: [targetIds: string[]]
  sendBackward: [targetIds: string[]]
  sendToBack: [targetIds: string[]]
  delete: [targetIds: string[]]
}>()

// Detect platform once at module load so the menu doesn't recompute
// on every render. Linux/Windows shows "Ctrl" + "+"; macOS shows
// unicode glyphs (⌘ ⇧ ⌫).
const isMac = computed(() => navigator.platform.includes('Mac'))
const acc = (mac: string, linux: string): string => (isMac.value ? mac : linux)

const hasSelection = computed(() => props.targetIds.length >= 1)
const canGroup = computed(() => props.targetIds.length >= 2)

// Leave group is enabled only when EXACTLY ONE element is selected AND that element has a non-empty
// `parent_id` (it's currently nested inside a group or frame). Mirrors Figma's "Pull out of group"
// — the affordance is greyed out for already top-level rows.
// Independent of `canUngroup`: a group/frame can ALSO be inside another group (nested), in which
// case both Leave group AND Ungroup can fire.
const canLeaveGroup = computed(() => {
  if (props.targetIds.length !== 1) return false
  const targetId = props.targetIds[0]
  if (!targetId) return false
  const target = props.elements.find((e) => e.id === targetId)
  if (!target) return false
  // `parent_id` arrives as '' (empty string) for top-level elements (the backend uses
  // COALESCE(parent_id, '')) or is undefined when the API returned an older shape. Both count as
  // "not inside a group" → disabled.
  return !!target.parent_id && target.parent_id !== ''
})

// Ungroup is enabled only when EXACTLY ONE element is selected AND
// that element's type is 'group' or 'frame'. Mirrors Figma's
// "greyed-out Ungroup for non-group single selections" rule.
const canUngroup = computed(() => {
  if (props.targetIds.length !== 1) return false
  const targetId = props.targetIds[0]
  if (!targetId) return false
  const target = props.elements.find((e) => e.id === targetId)
  if (!target) return false
  return target.type === 'group' || target.type === 'frame'
})

// Items dispatched through `v-for` to avoid repeating the same button markup 4 times. Each entry
// maps to one of the design's 4 reorder events. The single `reorder` handler below routes to the
// right emit by name.
const reorderItems = computed(() => [
  { id: 'bring-to-front', label: 'Bring to front', acc: acc('⌘⇧]', 'Ctrl+Shift+]'), emitName: 'bringToFront' as const },
  { id: 'bring-forward', label: 'Bring forward', acc: acc('⌘]', 'Ctrl+]'), emitName: 'bringForward' as const },
  { id: 'send-backward', label: 'Send backward', acc: acc('⌘[', 'Ctrl+['), emitName: 'sendBackward' as const },
  { id: 'send-to-back', label: 'Send to back', acc: acc('⌘⇧[', 'Ctrl+Shift+['), emitName: 'sendToBack' as const },
])

// "Move to page…" is enabled only when EXACTLY ONE element is selected.
// Mirrors Q2 (single element only, button greyed when multi-select).
const canMoveToPage = computed(() => props.targetIds.length === 1)

// Estimated menu footprint for viewport edge clamping. Counted from the items[] below: 11 buttons +
// 2 separators = 13 rows × 40px tall; 220px wide minimum. (Updated to include "Move to page…" which
// sits before the reorder items.)
const MENU_WIDTH = 220
const MENU_ROW_HEIGHT = 40
const MENU_ROWS = 13
const VIEWPORT_MARGIN = 8

const edgeClampedStyle = computed(() => {
  let x = props.x
  let y = props.y
  const menuHeight = MENU_ROW_HEIGHT * MENU_ROWS
  if (x + MENU_WIDTH > window.innerWidth - VIEWPORT_MARGIN) {
    x = Math.max(VIEWPORT_MARGIN, window.innerWidth - MENU_WIDTH - VIEWPORT_MARGIN)
  }
  if (y + menuHeight > window.innerHeight - VIEWPORT_MARGIN) {
    y = Math.max(VIEWPORT_MARGIN, window.innerHeight - menuHeight - VIEWPORT_MARGIN)
  }
  return {
    left: `${x}px`,
    top: `${y}px`,
  }
})

function dispatchReorder(item: typeof reorderItems.value[number]): void {
  // Switch on emitName (typed `as const`) so TS narrows the emit() call to the matching overload. A
  // simple `emit(item.emitName, ...)` is rejected by TS2769 because the union of emit names doesn't
  // auto-narrow to a single overload.
  switch (item.emitName) {
    case 'bringToFront': emit('bringToFront', [...props.targetIds]); return
    case 'bringForward': emit('bringForward', [...props.targetIds]); return
    case 'sendBackward': emit('sendBackward', [...props.targetIds]); return
    case 'sendToBack': emit('sendToBack', [...props.targetIds]); return
  }
}
</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed z-50 py-1 rounded-md shadow-lg"
      :style="{
        ...edgeClampedStyle,
        backgroundColor: 'var(--semantic-sidebar-bg)',
        border: '1px solid var(--color-border)',
        minWidth: '220px',
      }"
      data-testid="design-context-menu"
      @click.stop
    >
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canGroup"
        data-testid="design-context-menu-group"
        @click="emit('group', [...targetIds])"
      >
        <span>Group selection</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">{{ acc('⌘G', 'Ctrl+G') }}</span>
      </button>
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canLeaveGroup"
        data-testid="design-context-menu-leave-group"
        @click="emit('leaveGroup', targetIds[0]!)"
      >
        <span>Leave group</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">&nbsp;</span>
      </button>
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canUngroup"
        data-testid="design-context-menu-ungroup"
        @click="emit('ungroup', targetIds[0]!)"
      >
        <span>Ungroup</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">{{ acc('⌘⇧G', 'Ctrl+Shift+G') }}</span>
      </button>
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between"
        style="color: var(--semantic-text);"
        data-testid="design-context-menu-select-all"
        @click="emit('selectAll')"
      >
        <span>Select all</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">{{ acc('⌘A', 'Ctrl+A') }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" data-testid="design-context-menu-separator-1" />
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canMoveToPage"
        data-testid="design-context-menu-move-to-page"
        @click="emit('moveToPage', targetIds[0]!)"
      >
        <span>Move to page...</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">&nbsp;</span>
      </button>
      <button
        v-for="item in reorderItems"
        :key="item.id"
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        :data-testid="`design-context-menu-${item.id}`"
        @click="dispatchReorder(item)"
      >
        <span>{{ item.label }}</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">{{ item.acc }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" data-testid="design-context-menu-separator-2" />
      <button
        type="button"
        class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        data-testid="design-context-menu-delete"
        @click="emit('delete', [...targetIds])"
      >
        <span>Delete</span>
        <span class="text-dense" style="color: var(--semantic-text-dim);">{{ acc('⌫', 'Del') }}</span>
      </button>
    </div>
  </Teleport>
</template>