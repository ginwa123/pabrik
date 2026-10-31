<script setup lang="ts">
/** DiagramViewer — the one full-screen diagram inspector, shared by the mermaid, PlantUML and D2
 * blocks. A diagram too wide for the transcript column is unreadable in place, so this is where a
 * reader gets to look at it properly: fit, zoom around the cursor, drag, keyboard. */
import { computed, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import {
  KEYBOARD_PAN_PX,
  STAGE_FALLBACK,
  ZOOM_STEP,
  fittedViewport,
  formatZoom,
  panBy,
  zoomAround,
} from '../../helpers/diagramViewport'
import type { DiagramSize, DiagramViewport } from '../../helpers/diagramViewport'

const props = defineProps<{
  open: boolean
  label: string
  /** The drawing's intrinsic size, when the block knows it. `null` still zooms from 100%. */
  natural: DiagramSize | null
  /** Where the untouched original lives, for the diagrams rendered by a server. */
  original?: string
}>()

const emit = defineEmits<{ close: [] }>()

const rootEl = ref<HTMLElement | null>(null)
const stageEl = ref<HTMLElement | null>(null)
const stage = ref<DiagramSize>({ ...STAGE_FALLBACK })
const viewport = ref<DiagramViewport>({ zoom: 1, x: 0, y: 0 })
const dragging = ref(false)

let wasOpen: boolean | null = null
let overflowBefore = ''
let previousFocus: HTMLElement | null = null
let pointer: { x: number; y: number } | null = null
let dragged = 0

const zoomLabel = computed(() => formatZoom(viewport.value.zoom))

const contentStyle = computed(() => {
  const style: Record<string, string> = {
    transform: `translate(${viewport.value.x}px, ${viewport.value.y}px) scale(${viewport.value.zoom})`,
  }
  if (props.natural && props.natural.width > 0) style.width = `${props.natural.width}px`
  return style
})

const measureStage = (): void => {
  const element = stageEl.value
  const width = element?.clientWidth ?? 0
  const height = element?.clientHeight ?? 0
  stage.value = {
    width: width > 0 ? width : STAGE_FALLBACK.width,
    height: height > 0 ? height : STAGE_FALLBACK.height,
  }
}

const fit = (): void => {
  measureStage()
  viewport.value = fittedViewport(props.natural, stage.value)
}

const zoomTo = (next: number, anchor: { x: number; y: number } = { x: 0, y: 0 }): void => {
  viewport.value = zoomAround(viewport.value, next, anchor, props.natural, stage.value)
}

const zoomIn = (): void => zoomTo(viewport.value.zoom * ZOOM_STEP)
const zoomOut = (): void => zoomTo(viewport.value.zoom / ZOOM_STEP)

const toggleZoom = (): void => {
  const atFit = fittedViewport(props.natural, stage.value).zoom
  zoomTo(Math.abs(viewport.value.zoom - atFit) < 0.01 ? 1 : atFit)
}

const anchorFrom = (event: MouseEvent): { x: number; y: number } => {
  const box = stageEl.value?.getBoundingClientRect()
  if (!box || box.width <= 0) return { x: 0, y: 0 }
  return {
    x: event.clientX - (box.left + box.width / 2),
    y: event.clientY - (box.top + box.height / 2),
  }
}

const onBackdrop = (event: MouseEvent): void => {
  if (event.target === event.currentTarget) emit('close')
}

const onWheel = (event: WheelEvent): void => {
  const factor = event.deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP
  zoomTo(viewport.value.zoom * factor, anchorFrom(event))
}

const onPointerDown = (event: PointerEvent): void => {
  if (event.button !== 0) return
  dragged = 0
  pointer = { x: event.clientX, y: event.clientY }
  dragging.value = true
  const element = stageEl.value
  if (element && typeof element.setPointerCapture === 'function') {
    element.setPointerCapture(event.pointerId)
  }
}

const onPointerMove = (event: PointerEvent): void => {
  if (!pointer) return
  const dx = event.clientX - pointer.x
  const dy = event.clientY - pointer.y
  pointer = { x: event.clientX, y: event.clientY }
  dragged += Math.abs(dx) + Math.abs(dy)
  viewport.value = panBy(viewport.value, dx, dy, props.natural, stage.value)
}

/** A drag ends with a click on the stage; that one must not be read as "close". */
const onStageClick = (event: MouseEvent): void => {
  const wasDrag = dragged > 4
  dragged = 0
  if (wasDrag || event.target !== event.currentTarget) return
  emit('close')
}

const endDrag = (): void => {
  pointer = null
  dragging.value = false
}

const onWindowResize = (): void => {
  fit()
}

const onKeydown = (event: KeyboardEvent): void => {
  if (event.key === 'Escape') {
    event.stopPropagation()
    emit('close')
    return
  }
  if (event.key === '+' || event.key === '=') {
    event.preventDefault()
    zoomIn()
    return
  }
  if (event.key === '-' || event.key === '_') {
    event.preventDefault()
    zoomOut()
    return
  }
  if (event.key === '0') {
    event.preventDefault()
    fit()
    return
  }
  const pan: Record<string, { x: number; y: number }> = {
    ArrowLeft: { x: KEYBOARD_PAN_PX, y: 0 },
    ArrowRight: { x: -KEYBOARD_PAN_PX, y: 0 },
    ArrowUp: { x: 0, y: KEYBOARD_PAN_PX },
    ArrowDown: { x: 0, y: -KEYBOARD_PAN_PX },
  }
  const step = pan[event.key]
  if (!step) return
  event.preventDefault()
  viewport.value = panBy(viewport.value, step.x, step.y, props.natural, stage.value)
}

const release = (): void => {
  if (typeof document === 'undefined') return
  document.body.style.overflow = overflowBefore
  document.removeEventListener('keydown', onKeydown)
  window.removeEventListener('resize', onWindowResize)
  endDrag()
  if (previousFocus && previousFocus.isConnected) previousFocus.focus()
  previousFocus = null
}

const acquire = (): void => {
  if (typeof document === 'undefined') return
  previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null
  overflowBefore = document.body.style.overflow
  document.body.style.overflow = 'hidden'
  document.addEventListener('keydown', onKeydown)
  window.addEventListener('resize', onWindowResize)
  fit()
  rootEl.value?.focus()
}

const syncOpen = (open: boolean): void => {
  if (open === wasOpen) return
  wasOpen = open
  if (open) acquire()
  else release()
}

onMounted(() => syncOpen(props.open))
onUpdated(() => syncOpen(props.open))

onBeforeUnmount(() => {
  if (wasOpen) release()
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open"
      ref="rootEl"
      class="diagram-viewer"
      role="dialog"
      aria-modal="true"
      :aria-label="label"
      tabindex="-1"
      data-testid="diagram-viewer"
      @click="onBackdrop"
    >
      <div class="diagram-viewer-toolbar" @click.stop>
        <div class="diagram-viewer-group">
          <button
            type="button"
            class="diagram-viewer-button"
            aria-label="Zoom out"
            title="Zoom out (−)"
            data-testid="diagram-viewer-zoom-out"
            @click="zoomOut"
          >
            −
          </button>
          <span class="diagram-viewer-zoom" data-testid="diagram-viewer-zoom">{{ zoomLabel }}</span>
          <button
            type="button"
            class="diagram-viewer-button"
            aria-label="Zoom in"
            title="Zoom in (+)"
            data-testid="diagram-viewer-zoom-in"
            @click="zoomIn"
          >
            +
          </button>
          <button
            type="button"
            class="diagram-viewer-button"
            title="Fit the whole diagram (0)"
            data-testid="diagram-viewer-fit"
            @click="fit"
          >
            Fit
          </button>
          <span class="diagram-viewer-hint">Drag to pan, scroll to zoom</span>
        </div>
        <div class="diagram-viewer-group">
          <a
            v-if="original"
            class="diagram-viewer-button"
            :href="original"
            target="_blank"
            rel="noopener noreferrer"
            title="Open the original diagram in a new tab"
            data-testid="diagram-viewer-original"
          >
            Open original
          </a>
          <button
            type="button"
            class="diagram-viewer-button diagram-viewer-close"
            aria-label="Close diagram"
            title="Close (Esc)"
            data-testid="diagram-viewer-close"
            @click="emit('close')"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>
      </div>
      <div
        ref="stageEl"
        class="diagram-viewer-stage"
        :class="{ 'diagram-viewer-stage--dragging': dragging }"
        data-testid="diagram-viewer-stage"
        @click="onStageClick"
        @wheel.prevent="onWheel"
        @pointerdown="onPointerDown"
        @pointermove="onPointerMove"
        @pointerup="endDrag"
        @pointercancel="endDrag"
        @dblclick="toggleZoom"
      >
        <div class="diagram-viewer-content" :style="contentStyle" data-testid="diagram-viewer-content">
          <slot></slot>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.diagram-viewer {
  position: fixed;
  inset: 0;
  z-index: 9999;
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
  background-color: rgba(0, 0, 0, 0.88);
}

.diagram-viewer:focus {
  outline: none;
}

.diagram-viewer-toolbar {
  display: flex;
  flex: none;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 6px 12px;
  padding: 6px 8px;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
}

.diagram-viewer-group {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.diagram-viewer-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  height: 28px;
  min-width: 28px;
  padding: 0 10px;
  border: 1px solid var(--color-border, #282727);
  border-radius: 6px;
  background: var(--color-bg-p1, #282727);
  color: var(--semantic-text, #c5c9c5);
  font-size: var(--text-dense);
  text-decoration: none;
  cursor: pointer;
  transition: border-color 0.12s ease;
}

.diagram-viewer-button:hover {
  border-color: var(--color-violet, #8992a7);
}

.diagram-viewer-button:focus-visible {
  outline: 1px solid var(--semantic-link, #8ba4b0);
  outline-offset: 2px;
}

.diagram-viewer-close {
  padding: 0;
}

.diagram-viewer-zoom {
  min-width: 48px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
  font-variant-numeric: tabular-nums;
  text-align: center;
}

.diagram-viewer-hint {
  overflow: hidden;
  padding-left: 4px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
  white-space: nowrap;
  text-overflow: ellipsis;
}

.diagram-viewer-stage {
  position: relative;
  display: flex;
  flex: 1;
  align-items: center;
  justify-content: center;
  min-height: 0;
  overflow: hidden;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
  cursor: grab;
  touch-action: none;
  user-select: none;
}

.diagram-viewer-stage--dragging {
  cursor: grabbing;
}

.diagram-viewer-content {
  flex: none;
  transform-origin: center center;
}

.diagram-viewer-content :deep(svg) {
  display: block;
  max-width: 100% !important;
  height: auto;
}

.diagram-viewer-content :deep(img) {
  display: block;
  max-width: 100%;
  height: auto;
}

@media (max-width: 720px) {
  .diagram-viewer-hint {
    display: none;
  }
}

@media (prefers-reduced-motion: reduce) {
  .diagram-viewer-button {
    transition: none;
  }
}
</style>
