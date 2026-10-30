<script setup lang="ts">
import { computed } from 'vue'
import LayersPanel from './LayersPanel.vue'
import PropertiesPanel from './PropertiesPanel.vue'
import type { DesignElement as DesignElementApi } from '../../api'

const props = defineProps<{
  elements: DesignElementApi[]
  selectedIds: string[]
  isPreviewMode: boolean
  width: number
  layersRatio: number
  sidebarResizing: boolean
  layersResizing: boolean
}>()

const activeElements = computed<DesignElementApi[]>(() =>
  props.elements.filter((e) => props.selectedIds.includes(e.id)),
)

const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  reparent: [payload: { elementIds: string[]; newParentId: string | null }]
  reorder: [orderedElementIds: string[]]
  delete: [elementId: string]
  group: [targetIds: string[]]
  ungroup: [elementId: string]
  leaveGroup: [elementId: string]
  selectAll: []
  bringToFront: []
  bringForward: []
  sendBackward: []
  sendToBack: []
  contextMenuDelete: [targetIds: string[]]
  moveToPage: [elementId: string]
  update: [patch: Partial<DesignElementApi>]
  htmlChanged: [html: string]
  sidebarResizeStart: [event: MouseEvent]
  layersResizeStart: [event: MouseEvent]
}>()
</script>

<template>
  <!-- Resize handle (canvas ↔ right sidebar) -->
  <div
    class="shrink-0 w-2 cursor-col-resize relative flex items-center justify-center transition-colors"
    :class="
      sidebarResizing
        ? '!bg-[var(--color-violet)]/60'
        : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
    "
    data-testid="design-sidebar-resize-handle"
    title="Drag to resize"
    @mousedown="(event) => emit('sidebarResizeStart', event)"
  >
    <svg
      width="14"
      height="2"
      viewBox="0 0 14 2"
      fill="currentColor"
      class="text-[var(--color-violet)] opacity-70"
      aria-hidden="true"
    >
      <circle cx="3" cy="1" r="1" />
      <circle cx="7" cy="1" r="1" />
      <circle cx="11" cy="1" r="1" />
    </svg>
  </div>

  <!-- Right sidebar (Layers + Properties) -->
  <div
    class="shrink-0 flex flex-col h-full min-h-0"
    :style="{ width: `${width}px` }"
    data-testid="design-right-sidebar"
  >
    <!-- Layers (top, flexible height by layersHeightRatio) -->
    <div class="min-h-0 overflow-hidden" :style="{ height: `${layersRatio * 100}%` }">
      <LayersPanel
        :elements="elements"
        :selected-ids="selectedIds"
        :readonly="isPreviewMode"
        @select="emit('select', $event)"
        @reparent="emit('reparent', $event)"
        @reorder="emit('reorder', $event)"
        @delete="emit('delete', $event)"
        @group="emit('group', $event)"
        @ungroup="emit('ungroup', $event)"
        @leave-group="emit('leaveGroup', $event)"
        @select-all="emit('selectAll')"
        @bring-to-front="emit('bringToFront')"
        @bring-forward="emit('bringForward')"
        @send-backward="emit('sendBackward')"
        @send-to-back="emit('sendToBack')"
        @context-menu-delete="emit('contextMenuDelete', $event)"
        @move-to-page="emit('moveToPage', $event)"
      />
    </div>

    <!-- Horizontal resize handle between Layers and Properties -->
    <div
      class="shrink-0 h-2 cursor-row-resize transition-colors"
      :class="
        layersResizing
          ? '!bg-[var(--color-violet)]/60'
          : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
      "
      data-testid="design-layers-resize-handle"
      title="Drag to resize"
      @mousedown="(event) => emit('layersResizeStart', event)"
    />

    <!-- Properties (bottom, fills remaining height) -->
    <div class="flex-1 min-h-0 overflow-hidden">
      <PropertiesPanel
        :elements="activeElements"
        :readonly="false"
        :preview-mode="isPreviewMode"
        @update="emit('update', $event)"
        @html-changed="emit('htmlChanged', $event)"
        @delete="emit('delete', $event)"
      />
    </div>
  </div>
</template>
