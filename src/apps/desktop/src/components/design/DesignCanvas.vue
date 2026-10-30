<script setup lang="ts">
import { computed } from 'vue'
import DesignElement from './DesignElement.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import type { DesignElement as DesignElementApi } from '../../api'
import type { SnapGuide } from './useSnapGuides'

const props = defineProps<{
  elements: DesignElementApi[]
  selectedIds: string[]
  zoom: number
  workspaceId: string
  itemId: string
  pageId: string
  isPreviewMode: boolean
  snapGuides: SnapGuide[]
}>()

const workspacesStore = useWorkspacesStore()

const selectedId = computed<string | null>(() =>
  props.selectedIds.length === 1 ? (props.selectedIds[0] ?? null) : null,
)

// True while the active page's element fetch is in flight. Without it
// the canvas renders "Click + Element to add your first element" during
// the fetch — a false statement about the page's data.
const isElementsLoading = computed(() => {
  const itemId = props.itemId
  if (!itemId || !props.pageId) return false
  return workspacesStore.isDesignElementsLoading(itemId, props.pageId)
})

const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  update: [patch: Partial<DesignElementApi>]
  translate: [payload: { elementId?: string; dx: number; dy: number }]
  resize: [patch: Partial<DesignElementApi>]
  groupDrag: [delta: { dx: number; dy: number }]
  dragEnd: []
  dragStart: [ids: string[]]
  htmlChanged: [html: string]
  delete: [elementId: string]
  canvasClick: [event: MouseEvent]
  canvasWheel: [event: WheelEvent]
  pointerDown: [event: PointerEvent]
  pointerMove: [event: PointerEvent]
  pointerEnd: [event: PointerEvent]
  contextMenu: [event: MouseEvent]
}>()
</script>

<template>
  <!-- Canvas viewport -->
  <div
    class="flex-1 overflow-auto min-h-0"
    style="background-color: var(--color-bg-m2); touch-action: pan-x pan-y"
    data-testid="design-canvas-scroll-container"
    @click="emit('canvasClick', $event)"
    @wheel="emit('canvasWheel', $event)"
    @pointerdown="emit('pointerDown', $event)"
    @pointermove="emit('pointerMove', $event)"
    @pointerup="emit('pointerEnd', $event)"
    @pointercancel="emit('pointerEnd', $event)"
  >
    <div
      class="relative mx-auto my-6 origin-top-left"
      :style="{
        minWidth: '1440px',
        minHeight: '1024px',
        transform: `scale(${zoom})`,
      }"
      data-testid="design-canvas"
      @click.stop
      @contextmenu="emit('contextMenu', $event)"
    >
      <DesignElement
        v-for="element in elements"
        :key="element.id"
        :element="element"
        :selected="selectedId === element.id"
        :selected-ids="selectedIds"
        :readonly="false"
        :zoom="zoom"
        :workspace-id="workspaceId"
        :item-id="itemId"
        :page-id="pageId"
        :preview-mode="isPreviewMode"
        @select="(payload) => emit('select', payload)"
        @update="emit('update', $event)"
        @translate="emit('translate', $event)"
        @resize="emit('resize', $event)"
        @group-drag="emit('groupDrag', $event)"
        @drag-end="emit('dragEnd')"
        @drag-start="emit('dragStart', $event)"
        @html-changed="emit('htmlChanged', $event)"
        @delete="emit('delete', $event)"
      />
      <!--
        Snap guides (Chunk 3): SVG overlay rendered ABOVE the
        elements (z-index higher in DOM order) but BELOW the
        resize handles (which are inside each DesignElement).
        `pointer-events-none` so the SVG never intercepts the
        cursor — the canvas's own pointer handlers stay alive.
        1px violet lines: vertical = x-axis guides at a fixed
        position, full canvas height; horizontal = y-axis guides,
        full canvas width.

        The SVG fills the canvas div (which is now auto-grow,
        wrapping all elements). Guide line endpoints use `100%`
        so the lines span the full canvas div height/width
        regardless of the actual element positions.
      -->
      <svg
        v-if="snapGuides.length > 0"
        class="absolute inset-0 pointer-events-none"
        width="100%"
        height="100%"
        data-testid="design-snap-guides"
        aria-hidden="true"
      >
        <line
          v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'x')"
          :key="`x-${idx}`"
          :x1="guide.position"
          :y1="0"
          :x2="guide.position"
          y2="100%"
          stroke="var(--color-violet)"
          stroke-width="1"
        />
        <line
          v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'y')"
          :key="`y-${idx}`"
          :x1="0"
          :y1="guide.position"
          x2="100%"
          :y2="guide.position"
          stroke="var(--color-violet)"
          stroke-width="1"
        />
      </svg>
      <!-- Element-fetch skeleton — holds the canvas's height while
           the page's elements load, so the "Click + Element" empty
           state does not flash first. -->
      <div
        v-if="isElementsLoading"
        class="absolute inset-0 flex items-center justify-center pointer-events-none"
        data-testid="design-canvas-skeleton"
        role="status"
        aria-label="Loading elements"
      >
        <div class="w-full max-w-md space-y-3 px-8">
          <div
            v-for="w in ['100%', '72%', '88%', '60%']"
            :key="w"
            class="h-10 rounded animate-pulse"
            :style="{ width: w, backgroundColor: 'var(--semantic-active-bg)' }"
          ></div>
        </div>
      </div>
      <div
        v-else-if="elements.length === 0"
        class="absolute inset-0 flex items-center justify-center text-body pointer-events-none"
        style="color: var(--semantic-text-dim)"
        data-testid="design-canvas-empty"
      >
        <div class="text-center">
          <div class="text-display mb-2" aria-hidden="true">▢</div>
          <div>Click "+ Element" to add your first element</div>
        </div>
      </div>
    </div>
  </div>
</template>
