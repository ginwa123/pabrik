<!--
  LayerRow — recursive row for LayersPanel's tree render.

  One row per `DesignElement`. Indents by `depth * 16px`. If the
  element has children (`node.children.length > 0`), renders a ▶/▼
  chevron before the type icon to toggle collapse. When expanded,
  recursively renders each child as a `<LayerRow>` with `depth + 1`.

  Why a separate component:
  - Tests can mount `LayerRow` in isolation for tree behaviour.
  - LayersPanel stays focused on top-level wiring + the tree builder.
  - The recursive self-reference is clean (Vue 3 supports it via
    `defineOptions({ name: 'LayerRow' })`).

  Public API:
    props:
      node           LayerTreeNode    this row + its children
      depth          number           0 for top-level, +1 per nesting
      selectedIds    string[]         multi-aware selection array
      readonly       boolean          when true, hide up/down/delete
      collapsedIds   Set<string>      shared collapse state from parent
    emits:
      select           [{ elementId: string; additive: boolean }]
      delete           [string]                       (elementId)
      toggleCollapse   [string]                       (elementId)
      moveUp           [string]                       (elementId)
      moveDown         [string]                       (elementId)

  Test contract:
    data-testid="design-layer-${elementId}" on the row div
    data-testid="design-layer-toggle-${elementId}" on the chevron button
    data-testid="design-layer-reorder-up-${elementId}" on the up button
    data-testid="design-layer-reorder-down-${elementId}" on the down button
    data-testid="design-layer-delete-${elementId}" on the × button
-->
<script setup lang="ts">
import { computed } from 'vue'
import type { DesignElement } from '../../api'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

/** One node in the design-page layers tree. Each `DesignElement` can
 * have N nested children (when its `parent_id` points to a `group`
 * or `frame` element). The tree is built in `LayersPanel.vue` via
 * the `layerTree` computed. */
export interface LayerTreeNode {
  element: DesignElement
  children: LayerTreeNode[]
}

// Vue 3 requires either a script-level `name: 'LayerRow'` declaration
// OR `defineOptions({ name: 'LayerRow' })` in <script setup> for the
// recursive `<LayerRow>` usage in the template to type-check under
// vue-tsc. Without this, vue-tsc reports:
//
//   "Component LayerRow is not registered in any module"
//
// which silently passes in `bunx vitest run` but FAILS the strict
// type-check in `bun run build`. See
// `.pabrik/memories/pabrik-frontend-patterns.md` §"bun run build is
// the type-check" for the bun/Node vue-tsc split.
defineOptions({ name: 'LayerRow' })

const props = withDefaults(
  defineProps<{
    node: LayerTreeNode
    depth: number
    selectedIds: string[]
    readonly: boolean
    /** Shared collapse state from the parent. The parent owns a
     * `ref(new Set<string>())` and passes the Set down by reference.
     * Vue 3 reactivity requires the parent to REPLACE the Set (not
     * mutate it) to trigger re-renders — LayerRow just READS it. */
    collapsedIds: Set<string>
    /** Kind flag — 'row' is the default (a real element row).
     * 'drop-zone' renders the row as a non-draggable top-level
     * drop target used between top-level siblings. The parent
     * LayersPanel mounts these as synthetic rows with a sentinel
     * element id (`TOP_LEVEL_SENTINEL`). */
    kind?: 'row' | 'drop-zone'
    /** Optional drag-state visual flags from the parent. */
    isBeingDragged?: boolean
    isDropTarget?: boolean
    isDropTargetBlocked?: boolean
    /** Drag event callbacks. The parent (LayersPanel) owns the
     *  drag state machine via `useLayerDragDrop` and uses these
     *  hooks to drive it. When omitted (e.g. synthetic rows) the
     *  row stays passive. */
    onLayerDragStart?: (id: string, ev: DragEvent) => void
    onLayerDragOver?: (id: string, ev: DragEvent) => void
    onLayerDragLeave?: (id: string, ev: DragEvent) => void
    onLayerDrop?: (id: string, ev: DragEvent) => void
    onLayerDragEnd?: (ev: DragEvent) => void
  }>(),
  {
    kind: 'row',
    isBeingDragged: false,
    isDropTarget: false,
    isDropTargetBlocked: false,
  },
)

const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  delete: [elementId: string]
  toggleCollapse: [elementId: string]
  moveUp: [elementId: string]
  moveDown: [elementId: string]
  contextmenu: [payload: { event: MouseEvent; targetIds: string[] }]
}>()

const effectiveId = computed<string>(() =>
  props.kind === 'drop-zone' ? '__design_top_level__' : props.node.element.id,
)

// Computed flags for the row's visual state.
const isSelected = computed(() =>
  props.selectedIds.includes(props.node.element.id),
)
const isCollapsed = computed(() =>
  props.collapsedIds.has(props.node.element.id),
)
const hasChildren = computed(() => props.node.children.length > 0)

// Type icon — same mapping as the original LayersPanel. Kept here so
// the row is self-contained (no need to forward a helper from parent).
//
// The row's type mark is the only thing identifying it, so it comes from
// the shared `UiIcon` registry like every other icon in the app: one
// pixel box, one palette, and a name a spec can pin (`data-icon="note"`)
// instead of a box-drawing codepoint that renders at three different
// heights depending on the platform font.
const typeIcon = (type: DesignElement['type']): UiIconName => {
  switch (type) {
    case 'rectangle': return 'circle'
    case 'ellipse':   return 'circle'
    case 'text':      return 'note'
    case 'image':     return 'image'
    case 'frame':     return 'box'
    case 'group':     return 'cards'
    default:          return 'circle'
  }
}

const handleSelect = (event: MouseEvent): void => {
  // Figma parity: Shift OR Ctrl/Cmd click toggles membership in the multi-selection. Plain click
  // replaces the selection. Alt-click is intentional left unhandled (Linux/macOS window menu
  // shortcut) so it falls through to the plain-click path.
  const additive = event.shiftKey || event.ctrlKey || event.metaKey
  emit('select', {
    elementId: props.node.element.id,
    additive,
  })
}

const handleContextMenu = (event: MouseEvent): void => {
  // Figma parity: right-click on a row that IS in the multi-selection (regardless of shift) opens
  // the menu against the full selection. Right-click on an unselected row replaces the selection
  // with that single id and opens the menu against just that id.
  const isInSelection = props.selectedIds.includes(props.node.element.id)
  if (isInSelection) {
    emit('contextmenu', {
      event,
      targetIds: [...props.selectedIds],
    })
  } else {
    emit('select', { elementId: props.node.element.id, additive: false })
    emit('contextmenu', {
      event,
      targetIds: [props.node.element.id],
    })
  }
}

const handleDelete = (event: MouseEvent): void => {
  // Stop propagation so the click doesn't also fire `select`.
  event.stopPropagation()
  if (props.readonly) return
  emit('delete', props.node.element.id)
}

const handleMoveUp = (event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('moveUp', props.node.element.id)
}

const handleMoveDown = (event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('moveDown', props.node.element.id)
}

const handleChevronClick = (event: MouseEvent): void => {
  // Stop propagation so the chevron click doesn't also fire
  // `select` on the parent row.
  event.stopPropagation()
  emit('toggleCollapse', props.node.element.id)
}

// ─── Drag-and-drop handlers (Chunk 4 Task 4.1) ──────────────────────────
//
// These forward to the parent LayersPanel, which owns the drag state
// machine via `useLayerDragDrop`. The row itself stays passive —
// all logic (cycle check, multi-drag, top-level zones) lives in the
// composable so it can be tested without mounting the component.

const handleDragStart = (event: DragEvent): void => {
  if (props.kind === 'drop-zone' || props.readonly) {
    event.preventDefault()
    return
  }
  props.onLayerDragStart?.(props.node.element.id, event)
}

const handleDragOver = (event: DragEvent): void => {
  props.onLayerDragOver?.(effectiveId.value, event)
}

const handleDragLeave = (event: DragEvent): void => {
  props.onLayerDragLeave?.(effectiveId.value, event)
}

const handleDrop = (event: DragEvent): void => {
  event.preventDefault()
  props.onLayerDrop?.(effectiveId.value, event)
}

const handleDragEnd = (event: DragEvent): void => {
  props.onLayerDragEnd?.(event)
}
</script>

<template>
  <!-- Drop-zone rows: synthetic inert rows used as drag-drop targets
       between top-level element rows (one BEFORE the first element +
       one AFTER every element). They are NOT real element rows and
       MUST NOT render any of the row chrome (chevron, type icon,
       "(unnamed)" name placeholder, action buttons). The handler
       attrs above still bind @dragover/@drop/@dragleave/@dragend
       through the `<div>` below — only the visible chrome is gated. -->
  <div
    v-if="kind === 'drop-zone'"
    :class="[
      'layer-row-drop-zone-base',
      isDropTarget && 'layer-row-drop-target',
      isDropTargetBlocked && 'layer-row-drop-target-blocked',
    ]"
    :data-testid="'design-layer-drop-zone-top-level'"
    @click.stop
    @contextmenu.stop
    @dragover.prevent="handleDragOver"
    @dragleave="handleDragLeave"
    @drop="handleDrop"
    @dragend="handleDragEnd"
  ></div>

  <!-- The row itself. paddingLeft scales by depth so children
       visually nest under their parent. -->
  <div
    v-else
    :draggable="!readonly"
    :class="[
      'flex items-center gap-2 px-2 py-1.5 text-body cursor-pointer transition-colors',
      isBeingDragged && 'layer-row-dragging',
      isDropTarget && 'layer-row-drop-target',
      isDropTargetBlocked && 'layer-row-drop-target-blocked',
    ]"
    :style="{
      paddingLeft: `${depth * 16}px`,
      backgroundColor: isSelected
        ? 'var(--semantic-active-bg)'
        : 'transparent',
      color: isSelected
        ? 'var(--semantic-text)'
        : 'var(--semantic-text-dim)',
    }"
    :data-testid="`design-layer-${node.element.id}`"
    @click="handleSelect"
    @contextmenu="handleContextMenu"
    @dragstart="handleDragStart"
    @dragover.prevent="handleDragOver"
    @dragleave="handleDragLeave"
    @drop="handleDrop"
    @dragend="handleDragEnd"
  >
    <!-- Chevron (only when the node has children). Spacer span on
         leaf nodes keeps the type icon vertically aligned. -->
    <button
      v-if="hasChildren"
      type="button"
      class="w-4 h-4 flex items-center justify-center text-dense shrink-0"
      :data-testid="`design-layer-toggle-${node.element.id}`"
      :aria-label="isCollapsed ? 'Expand' : 'Collapse'"
      @click="handleChevronClick"
    >{{ isCollapsed ? '▶' : '▼' }}</button>
    <span
      v-else
      class="w-4 h-4 shrink-0"
      aria-hidden="true"
    ></span>

    <!-- Type icon. -->
    <UiIcon
      :name="typeIcon(node.element.type)"
      class="w-4 h-4"
      style="color: var(--color-violet);"
    />

    <!-- Element name. (The "(unnamed)" placeholder used to live here,
         but it leaked into the drop-zone rows that share this template
         — see the v-if above. Real element rows now just render the
         name; empty names render as an empty string.) -->
    <span class="flex-1 truncate">{{ node.element.name }}</span>

    <!-- Action buttons (reorder + delete). Hidden in readonly. -->
    <div
      v-if="!readonly"
      class="flex items-center gap-0.5 shrink-0"
      @click.stop
    >
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-dense rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
        :draggable="false"
        :data-testid="`design-layer-reorder-up-${node.element.id}`"
        :aria-label="`Move ${node.element.name} up`"
        @click="handleMoveUp"
      >▲</button>
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-dense rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
        :draggable="false"
        :data-testid="`design-layer-reorder-down-${node.element.id}`"
        :aria-label="`Move ${node.element.name} down`"
        @click="handleMoveDown"
      >▼</button>
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-dense rounded hover:bg-[var(--color-violet)]/30"
        :draggable="false"
        :data-testid="`design-layer-delete-${node.element.id}`"
        :aria-label="`Delete ${node.element.name}`"
        @click="handleDelete"
      >×</button>
    </div>
  </div>

  <!-- Recursive children. Only render when the parent is expanded
       AND the node has children. The template-side guard avoids
       emitting an empty fragment. -->
  <template v-if="hasChildren && !isCollapsed">
    <LayerRow
      v-for="child in node.children"
      :key="child.element.id"
      :node="child"
      :depth="depth + 1"
      :selected-ids="selectedIds"
      :collapsed-ids="collapsedIds"
      :readonly="readonly"
      @select="(p) => emit('select', p)"
      @delete="(id) => emit('delete', id)"
      @toggle-collapse="(id) => emit('toggleCollapse', id)"
      @move-up="(id) => emit('moveUp', id)"
      @move-down="(id) => emit('moveDown', id)"
      @contextmenu="(p) => emit('contextmenu', p)"
    />
  </template>
</template>

<style scoped>
.layer-row-dragging {
  opacity: 0.5;
  cursor: grabbing !important;
}
.layer-row-drop-target {
  outline: 1px solid var(--color-violet);
  outline-offset: -1px;
  background-color: rgba(127, 0, 255, 0.08);
}
.layer-row-drop-target-blocked {
  cursor: not-allowed;
  opacity: 0.6;
}

/* Drop-zone rows: an invisible 6px-tall spacer between element rows
   that acts as a drag-drop target. On hover/drag, `layer-row-drop-target`
   (above) lights up the full row with a violet outline. The visual
   treatment is intentionally subtle so the drop target only appears
   when the user is actively dragging — see Chunk 4 Task 4.2 of the
   design-layer-drag-join-or-leave-group plan. */
.layer-row-drop-zone-base {
  height: 6px;
  cursor: default;
  margin: 0;
  padding: 0;
  /* Subtle hint that this is a drop target even when idle. */
  background-color: transparent;
  transition: background-color 120ms ease;
}
.layer-row-drop-zone-base:hover {
  background-color: rgba(127, 0, 255, 0.04);
}
</style>
