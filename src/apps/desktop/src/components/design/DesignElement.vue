<!--
  DesignElement — a single positioned element on the design canvas.

  Renders the element as an absolutely-positioned div with the
  element's geometry (x, y, width, height) and a rotation transform.
  Selection state adds a violet outline; 8 resize handles (corners +
  edge midpoints) appear only when selected.

  Drag/resize:
    - Uses pointerdown / pointermove / pointerup + setPointerCapture
      so a fast drag that outruns the handle still tracks correctly.
    - The initial pointerdown records the start geometry and the
      pointer's screen position. Each pointermove computes the delta
      from the start position and applies it to the geometry; the
      emit fires only on pointerup (the design mode redraws from the
      emit, so 60+/sec would flood the canvas).
    - For drag: delta is applied to x/y.
    - For resize: delta is applied to width/height (sign flipped per
      handle so top/left handles grow when the user drags up/left).
    - For rotate: not implemented in v1 (the rotation field exists on
      the element but the canvas UX doesn't yet have a rotation handle;
      the PropertiesPanel can set rotation via a number input).

  Iframe content inside the element is rendered with pointer-events:none
  so the parent div owns the pointer events for drag/resize/select.
  This is the standard Figma/Sketch pattern.

  Public API:
    props:
      element   DesignElement   the element's full record
      selected  boolean         selection state (violet outline)
      readonly  boolean         when true, drag/resize are disabled
    emits:
      select       [elementId: string]
      update       [patch: Partial<DesignElement>]
      htmlChanged  [html: string]
      delete       [elementId: string]

  Test contract:
    - data-testid="design-element" on the wrapper
    - data-testid="design-element-handle-{corner}" on each resize handle
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import type { DesignElement } from '../../api'
import { getDesignElementHtml } from '../../api'
import DesignElementPreview from './DesignElementPreview.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { abbrevElement, designLogger } from '../../helpers/designLogger'

const props = withDefaults(
  defineProps<{
    element: DesignElement
    // Single-element shortcut (kept for backward compat with tests + simple use cases).
    selected?: boolean
    // The full selection set (Figma multi-select model).
    selectedIds?: string[]
    readonly?: boolean
    // Current canvas zoom level (1.0 = 100%). When the canvas is CSS-scaled via `transform
    zoom?: number
    // IDs needed to lazy-load the element's HTML body from the backend (the page+elements GET response excludes the body to keep payloads small).
    workspaceId?: string
    itemId?: string
    pageId?: string
    // When true, the parent canvas is in Preview/Edit mode (toggle in the canvas header bar).
    previewMode?: boolean
  }>(),
  {
    selected: false,
    selectedIds: () => [] as string[],
    readonly: false,
    zoom: 1.0,
    workspaceId: '',
    itemId: '',
    pageId: '',
    previewMode: false,
  },
)

const emit = defineEmits<{
  // Chunk 3: select now carries an `additive` flag so the canvas's Shift+click can toggle membership in the multi-selection Set (Figma parity with the layers panel …
  select: [payload: { elementId: string; additive: boolean }]
  /** DEPRECATED — replaced by `translate` (move) and `resize` (Figma parity with the backend's POST /translate + POST /resize split). */
  update: [patch: Partial<DesignElement>]
  /** NEW (2026-08-06) — fires on every pointermove during a drag for a SINGLE element (leaf OR a single-element drag of a group that didn't trigger the group-drag … */
  translate: [payload: { elementId: string; dx: number; dy: number }]
  /** NEW (2026-08-06) — fires on every pointermove during a RESIZE gesture (dragging one of the 8 resize handles). */
  resize: [patch: Partial<DesignElement>]
  // Chunk 2: when the user drags an element that's part of a multi-selection, the WHOLE selection moves.
  groupDrag: [delta: { dx: number; dy: number }]
  // Chunk 3: emit on drag-end (pointerup or pointercancel) so the parent can clear its snap guides.
  dragEnd: []
  // Undo/redo plan: emit on drag-start so the parent can capture pre-state for the eventual undo entry.
  dragStart: [ids: string[]]
  htmlChanged: [html: string]
  delete: [elementId: string]
}>()

// ─── Geometry ───────────────────────────────────────────────────────────
const elementStyle = computed(() => ({
  left: `${props.element.x}px`,
  top: `${props.element.y}px`,
  width: `${props.element.width}px`,
  height: `${props.element.height}px`,
  transform: `rotate(${props.element.rotation}deg)`,
  // Inline opacity; the backend's `opacity` field defaults to 1.0 and the v-if on the parent only renders elements with valid geometry, so no extra defensive …
  opacity: props.element.opacity,
  // FIX 2026-08-06 (task_1785988530202): apply `z-index` inline so CSS handles the z-axis stacking.
  zIndex: props.element.z_index,
  // Selection outline is rendered as a child absolutely-positioned div via the .selected class below; the parent keeps the standard border styling from the element …
}))

// ─── Drag (move) ────────────────────────────────────────────────────────
type DragMode = 'move' | { resize: ResizeHandle }

type ResizeHandle = 'nw' | 'n' | 'ne' | 'w' | 'e' | 'sw' | 's' | 'se'

const isDragging = ref(false)

// Workspace store — used to look up the parent element by id when the user clicks on a child.
const workspacesStore = useWorkspacesStore()

// True when this element is nested inside a parent group/frame.
const isChildOfGroup = computed(() => {
  const pid = props.element.parent_id
  return !!pid && pid !== ''
})

// The immediate parent element, looked up from the workspace store's `item.design_elements[]` array (the mirrored backend payload).
const parentElement = computed<DesignElement | null>(() => {
  const pid = props.element.parent_id
  if (!pid || pid === '') return null
  if (!props.workspaceId || !props.itemId) return null
  const ws = workspacesStore.workspaces.find((w) => w.id === props.workspaceId)
  if (!ws) return null
  const item = ws.items.find((i) => i.id === props.itemId)
  if (!item?.design_elements) return null
  return item.design_elements.find((e) => e.id === pid) ?? null
})

const startDrag = (event: PointerEvent, mode: DragMode): void => {
  // The 8 resize handles are children of the .design-element wrapper.
  console.log('GIL START DDRAGGING', mode)

  if (mode !== 'move') {
    event.stopPropagation()
  }
  console.log('GIL START DDRAGGING props', props)

  if (props.readonly) {
    designLogger.debug({
      reason: 'drag:noop:readonly',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })

    return
  }
  // In Preview mode, the canvas is "playing" the mockup — clicks on element bodies are absorbed by the inner iframe (typed text, button activations).
  if (props.previewMode) {
    designLogger.debug({
      reason: 'drag:noop:preview',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    return
  }
  // Don't initiate a drag if the click was on an interactive child (e.g. the iframe content) — pointer-events:none on the iframe already prevents that, but we …
  if (event.button !== 0) {
    designLogger.debug({
      reason: 'drag:noop:button≠0',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    console.log('GIL START DDRAGGING button', event)
    return
  }
  // ─── Click on child: select the parent group instead ─────────────────
  const useParentSelect = !event.shiftKey && isChildOfGroup.value && parentElement.value !== null
  const selectTarget = useParentSelect ? parentElement.value : null
  const selectElementId = selectTarget ? selectTarget.id : props.element.id

  emit('select', {
    elementId: selectElementId,
    additive: event.shiftKey,
  })
  if (selectTarget) {
    designLogger.info({
      reason: 'emit:select:parent-of-child',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
      extra: {
        parentId: selectTarget.id,
        parentName: selectTarget.name,
        additive: event.shiftKey,
        mode,
      },
    })
  } else {
    designLogger.info({
      reason: 'emit:select',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
      extra: { additive: event.shiftKey, mode },
    })
  }

  // ─── Child-of-group: block single-element move drag ─────────────────
  const inMultiSelect = props.selectedIds.length > 1 && props.selectedIds.includes(props.element.id)
  if (mode === 'move' && isChildOfGroup.value && !inMultiSelect) {
    designLogger.debug({
      reason: 'drag:noop:child-of-group',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    return
  }

  // Undo/redo plan (Chunk 4): emit drag-start BEFORE the gesture branches so the parent can capture pre-state.
  const groupDragIds =
    props.selectedIds.length > 1 && props.selectedIds.includes(props.element.id) && mode === 'move'
      ? props.selectedIds
      : [props.element.id]
  emit('dragStart', groupDragIds)
  designLogger.info({
    reason: 'emit:dragStart',
    caller: 'DesignElement.startDrag',
    element: abbrevElement(props.element),
    extra: { groupDragIds: [...groupDragIds], mode },
  })

  // Group drag (Chunk 2): when this element is part of a multi-selection, dragging moves the ENTIRE selection.
  const isGroupLike = props.element.type === 'group' || props.element.type === 'frame'
  const inMultiselect = props.selectedIds.length > 1 && props.selectedIds.includes(props.element.id)
  const triggerGroupDrag = (inMultiselect || isGroupLike) && mode === 'move'
  if (triggerGroupDrag) {
    console.log('GIL START DDRAGGING trigger group drags', triggerGroupDrag)
    event.preventDefault()
    const target = event.currentTarget as HTMLElement | null
    if (!target) {
      console.log('GIL START DDRAGGING trigger group drags null target', target)
      return
    }
    target.setPointerCapture(event.pointerId)
    isDragging.value = true
    const startClientX = event.clientX
    const startClientY = event.clientY
    let pendingDx = 0
    let pendingDy = 0
    // BUG FIX (2026-08-06, design-mode-moves-so-fast v2): send INCREMENTAL dx/dy (delta since last emit), NOT the cumulative cursor distance from drag-start.
    let lastEmittedDx = 0
    let lastEmittedDy = 0
    let lastEmitMs = 0
    const THROTTLE_MS = 50
    designLogger.info({
      reason: 'drag:start:group',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
      isGroup: true,
      startClientX,
      startClientY,
    })
    const onMove = (e: PointerEvent): void => {
      const inv = 1 / Math.max(0.01, props.zoom)
      pendingDx = (e.clientX - startClientX) * inv
      pendingDy = (e.clientY - startClientY) * inv
      const now = performance.now()
      if (now - lastEmitMs >= THROTTLE_MS) {
        // INCREMENTAL delta — server ADDs this to the current position.
        const incDx = pendingDx - lastEmittedDx
        const incDy = pendingDy - lastEmittedDy
        emit('groupDrag', { dx: incDx, dy: incDy })
        lastEmittedDx = pendingDx
        lastEmittedDy = pendingDy
        lastEmitMs = now
        designLogger.debug({
          reason: 'drag:throttled-emit',
          caller: 'DesignElement.startDrag',
          element: abbrevElement(props.element),
          dx: incDx,
          dy: incDy,
          // Also log the cumulative so debugging is easier.
          extra: {
            cumulativeDx: pendingDx,
            cumulativeDy: pendingDy,
            startClientX,
            startClientY,
          },
          isGroup: true,
        })
      }
    }
    const onUp = (e: PointerEvent): void => {
      if (target.hasPointerCapture(e.pointerId)) {
        target.releasePointerCapture(e.pointerId)
      }
      isDragging.value = false
      // Trailing emit: capture the final position regardless of throttle.
      const incDx = pendingDx - lastEmittedDx
      const incDy = pendingDy - lastEmittedDy
      emit('groupDrag', { dx: incDx, dy: incDy })
      lastEmittedDx = pendingDx
      lastEmittedDy = pendingDy
      designLogger.info({
        reason: 'drag:trailing-emit',
        caller: 'DesignElement.startDrag',
        element: abbrevElement(props.element),
        dx: incDx,
        dy: incDy,
        extra: {
          cumulativeDx: pendingDx,
          cumulativeDy: pendingDy,
          startClientX,
          startClientY,
        },
        isGroup: true,
      })
      // Chunk 3: tell the parent to clear its snap guides.
      emit('dragEnd')
      designLogger.info({
        reason: 'emit:dragEnd',
        caller: 'DesignElement.startDrag',
        element: abbrevElement(props.element),
      })
      target.removeEventListener('pointermove', onMove)
      target.removeEventListener('pointerup', onUp)
      target.removeEventListener('pointercancel', onUp)
    }
    target.addEventListener('pointermove', onMove)
    target.addEventListener('pointerup', onUp)
    target.addEventListener('pointercancel', onUp)
    return
  }

  // ─── Single-element drag path log ──────────────────────────────────
  designLogger.info({
    reason: 'drag:start:move',
    caller: 'DesignElement.startDrag',
    element: abbrevElement(props.element),
    isGroup: false,
    startClientX: event.clientX,
    startClientY: event.clientY,
  })

  // Single-element drag. 50 ms leading-edge throttle + trailing pointerup emit.
  event.preventDefault()

  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isDragging.value = true

  const startX = event.clientX
  const startY = event.clientY
  const start = {
    x: props.element.x,
    y: props.element.y,
    width: props.element.width,
    height: props.element.height,
  }
  // Overwrite the drag:start:move info above with a more-specific reason (resize vs move) using `mode`.
  designLogger.info({
    reason: mode === 'move' ? 'drag:start:move' : 'drag:start:resize',
    caller: 'DesignElement.startDrag',
    element: abbrevElement(props.element),
    isGroup: false,
    startClientX: startX,
    startClientY: startY,
    extra: { mode: typeof mode === 'string' ? mode : mode.resize },
  })

  // The latest pending event we intend to emit.
  let pendingTranslate: { dx: number; dy: number } | null = null
  let pendingResize: Partial<DesignElement> | null = null
  let lastEmitMs = 0
  let lastEmittedTranslateDx = 0
  let lastEmittedTranslateDy = 0
  const THROTTLE_MS = 50

  const flushEmit = (): void => {
    if (pendingTranslate) {
      const incDx = pendingTranslate.dx - lastEmittedTranslateDx
      const incDy = pendingTranslate.dy - lastEmittedTranslateDy
      // Carry the source elementId in the event so the parent doesn't have to fish it out of `selectedIds` (which can be wrong — see the doc on the `translate` emit …
      emit('translate', {
        elementId: props.element.id,
        dx: incDx,
        dy: incDy,
      })
      lastEmittedTranslateDx = pendingTranslate.dx
      lastEmittedTranslateDy = pendingTranslate.dy
      designLogger.debug({
        reason: 'emit:translate',
        caller: 'DesignElement.startDrag',
        element: abbrevElement(props.element),
        dx: incDx,
        dy: incDy,
        startClientX: startX,
        startClientY: startY,
        extra: { cumulativeDx: pendingTranslate.dx, cumulativeDy: pendingTranslate.dy },
        isGroup: false,
      })
      pendingTranslate = null
      lastEmitMs = performance.now()
    }
    if (pendingResize) {
      emit('resize', pendingResize)
      designLogger.debug({
        reason: 'emit:resize',
        caller: 'DesignElement.startDrag',
        element: abbrevElement(props.element),
        patch: pendingResize,
        startClientX: startX,
        startClientY: startY,
        isGroup: false,
      })
      pendingResize = null
      lastEmitMs = performance.now()
    }
  }

  const computeResizePatch = (dx: number, dy: number): Partial<DesignElement> => {
    const patch: Partial<DesignElement> = {}
    // Narrowing: at this point `mode` must be the `{ resize: ResizeHandle }` variant because the `if (mode === 'move')` branch above returned.
    const resizeMode = mode as { resize: ResizeHandle }
    const h = resizeMode.resize
    if (h.includes('e')) patch.width = Math.max(10, Math.round(start.width + dx))
    if (h.includes('s')) patch.height = Math.max(10, Math.round(start.height + dy))
    if (h.includes('w')) {
      patch.width = Math.max(10, Math.round(start.width - dx))
      patch.x = Math.round(start.x + (start.width - (patch.width ?? start.width)))
    }
    if (h.includes('n')) {
      patch.height = Math.max(10, Math.round(start.height - dy))
      patch.y = Math.round(start.y + (start.height - (patch.height ?? start.height)))
    }
    return patch
  }

  const onMove = (e: PointerEvent): void => {
    const inv = 1 / Math.max(0.01, props.zoom)
    const dx = (e.clientX - startX) * inv
    const dy = (e.clientY - startY) * inv
    if (mode === 'move') {
      pendingTranslate = { dx: Math.round(dx), dy: Math.round(dy) }
    } else {
      pendingResize = computeResizePatch(dx, dy)
    }
    const now = performance.now()
    if (now - lastEmitMs >= THROTTLE_MS) {
      flushEmit()
    }
  }

  const onUp = (e: PointerEvent): void => {
    if (target.hasPointerCapture(e.pointerId)) {
      target.releasePointerCapture(e.pointerId)
    }
    isDragging.value = false
    // Trailing emit: capture the final position regardless of throttle.
    flushEmit()
    // Chunk 3: tell the parent to clear its snap guides.
    emit('dragEnd')
    designLogger.info({
      reason: 'emit:dragEnd',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    target.removeEventListener('pointermove', onMove)
    target.removeEventListener('pointerup', onUp)
    target.removeEventListener('pointercancel', onUp)
  }

  target.addEventListener('pointermove', onMove)
  target.addEventListener('pointerup', onUp)
  target.addEventListener('pointercancel', onUp)
}

// ─── HTML preview wrapper ───────────────────────────────────────────────
const htmlBody = ref<string>('')
const htmlLoadError = ref<string | null>(null)
const isLoadingHtml = ref(false)
let htmlFetchSeq = 0

const fetchHtml = async (): Promise<void> => {
  // No file_path = no HTML body to render.
  if (!props.element.file_path) {
    htmlBody.value = ''
    htmlLoadError.value = null
    isLoadingHtml.value = false
    return
  }
  // Need the full id tuple to call the API; the parent's `fetchDesignElements` call doesn't carry them through to here yet, so guard gracefully.
  if (!props.workspaceId || !props.itemId || !props.pageId) {
    htmlBody.value = ''
    return
  }
  const seq = ++htmlFetchSeq
  isLoadingHtml.value = true
  htmlLoadError.value = null
  try {
    const { html } = await getDesignElementHtml(
      props.workspaceId,
      props.itemId,
      props.pageId,
      props.element.id,
    )
    // Only commit the result if this is still the latest in-flight request; otherwise a stale fetch could clobber newer content.
    if (seq === htmlFetchSeq) {
      htmlBody.value = html
    }
  } catch (err) {
    if (seq === htmlFetchSeq) {
      htmlLoadError.value = err instanceof Error ? err.message : String(err)
      htmlBody.value = ''
    }
  } finally {
    if (seq === htmlFetchSeq) {
      isLoadingHtml.value = false
    }
  }
}

onMounted(() => {
  prevHtmlKey.value = htmlKey()
  void fetchHtml()
})

// Re-fetch when the element identity, file path, or updated_at changes.
const prevHtmlKey = ref('')
const htmlKey = () => `${props.element.id}|${props.element.file_path}|${props.element.updated_at}`
onUpdated(() => {
  const key = htmlKey()
  if (key !== prevHtmlKey.value) {
    prevHtmlKey.value = key
    void fetchHtml()
  }
})

// ─── Delete (Delete/Backspace key on the selected element) ──────────────
import { onUnmounted } from 'vue'

const handleKeydown = (e: KeyboardEvent): void => {
  // Chunk 2: gate on the full selection set, not just this element's `selected` flag.
  if (props.selectedIds.length === 0 && !props.selected) return
  if (props.readonly) return
  if (e.key !== 'Delete' && e.key !== 'Backspace') return
  // Don't intercept Delete when the user is typing in a form input.
  const target = e.target as HTMLElement | null
  if (
    target &&
    (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)
  ) {
    return
  }
  e.preventDefault()
  // Emit one `delete` per selected id.
  for (const id of props.selectedIds.length > 0 ? props.selectedIds : [props.element.id]) {
    emit('delete', id)
  }
}

onMounted(() => {
  document.addEventListener('keydown', handleKeydown)
})
onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})
</script>

<template>
  <div
    class="design-element absolute"
    :class="[
      selected || selectedIds.includes(element.id) ? 'selected' : '',
      readonly ? 'cursor-default' : isChildOfGroup ? 'cursor-pointer' : 'cursor-move',
      isDragging ? 'dragging' : '',
    ]"
    :style="elementStyle"
    :data-testid="`design-element-${element.id}`"
    data-design-element="true"
    :data-preview-mode="previewMode"
    @pointerdown="(e) => startDrag(e, 'move')"
  >
    <!-- Iframe preview with pointer-events:none so the parent owns
         the pointer events. The iframe is positioned to fill the
         element's geometry; when the user wants to interact with the
         preview's content, they can use the PropertiesPanel's Monaco
         editor instead. -->
    <div
      v-if="element.file_path"
      class="absolute inset-0 pointer-events-none overflow-hidden"
      :style="{
        backgroundColor: element.fill || 'transparent',
        borderRadius: `${element.corner_radius}px`,
        border: element.stroke ? `${element.stroke_width}px solid ${element.stroke}` : 'none',
      }"
    >
      <!-- The HTML body is fetched on mount (and re-fetched when
           element.id / file_path / updated_at changes). The
           v-if="htmlBody" guard renders the placeholder rectangle
           underneath while the fetch is in flight, so the user sees
           a graceful loading state instead of a flash of empty.
           `pointerEvents` is `'none'` in Edit mode (clicks pass
           through to the wrapper for drag/resize/select) and
           `'auto'` in Preview mode (the iframe captures clicks so
           the user can type into inputs / click buttons).

           `:fill="element.fill"` passes the element's CSS fill color
           through to the iframe's background so the element renders
           with its true color even when its srcdoc HTML is empty
           (e.g. an empty `<div style="width:100%;height:100%;"></div>`
           that relies on the wrapper fill to show through). Without
           this, the iframe's hardcoded `background: white` (the old
           default) leaked white specks onto the canvas for every
           element with `fill: ''` or `fill: 'transparent'`. -->
      <DesignElementPreview
        v-if="htmlBody"
        :html="htmlBody"
        :editable="false"
        :pointer-events="previewMode ? 'auto' : 'none'"
        :fill="element.fill"
      />
      <!-- Loading state — empty until the iframe loads. Visible only
           briefly; the iframe replaces it within one render cycle of
           the fetch returning. -->
      <div
        v-else-if="isLoadingHtml"
        class="absolute inset-0 flex items-center justify-center text-micro"
        style="color: var(--semantic-text-dim)"
        data-testid="design-element-loading"
      >
        loading…
      </div>
    </div>

    <!-- Plain rectangle / shape fill. Acts as the dashed-outline
         fallback when there's no iframe to show: (a) the element
         has no file_path (legacy), (b) the HTML fetch failed.

         BUG FIX (2026-07-26): the previous version rendered this
         div unconditionally. Because both this div and the iframe
         wrapper above use `position: absolute; inset: 0` (and there
         is no `z-index`), the DOM order wins for stacking — this
         div is ON TOP of the iframe wrapper. Its `backgroundColor:
         element.fill` (e.g. `#ffffff` for chat-area.html) covered
         the rendered iframe content, making the canvas appear blank
         white even when the API had returned real HTML.

         The author had added `pointer-events-none` (so clicks pass
         through), but `pointer-events` only affects pointer events —
         NOT visual rendering. The bug was silent: the user only
         saw the iframe's bg color (often white) and concluded
         "design mode is white".

         The `v-if` gate below hides the rectangle whenever an
         iframe is rendering (loaded OR loading). `!htmlBody` covers
         the loaded case; `!isLoadingHtml` keeps the "loading…"
         text inside the wrapper visible (the wrapper is BELOW this
         div in DOM order, so a solid-bg rectangle would otherwise
         cover the loading text too).

         `pointer-events-none` is still needed when this div IS
         rendered (the legacy / failed cases) — without it, the
         dashed-outline div would capture drag/resize/select clicks
         that should reach the parent DesignElement wrapper. -->
    <div
      v-if="!htmlBody && !isLoadingHtml"
      class="absolute inset-0 pointer-events-none"
      :style="{
        backgroundColor: element.fill || 'rgba(127, 127, 127, 0.05)',
        borderRadius: `${element.corner_radius}px`,
        border: element.stroke
          ? `${element.stroke_width}px solid ${element.stroke}`
          : '1px dashed rgba(127, 127, 127, 0.4)',
      }"
    />

    <!-- Element name label (top-left corner) — useful when the shape
         is small / fill is invisible. -->
    <div
      class="absolute -top-5 left-0 text-micro pointer-events-none whitespace-nowrap"
      style="color: var(--semantic-text-dim)"
      v-if="selected && !previewMode"
    >
      {{ element.name }}
    </div>

    <!-- Text element content -->
    <div
      v-if="element.type === 'text' && element.text_content"
      class="absolute inset-0 flex items-center justify-center p-2 text-center overflow-hidden"
      :style="{
        fontFamily: element.text_style || 'sans-serif',
        color: element.stroke || 'var(--semantic-text)',
        fontSize: `${Math.max(8, element.width / 12)}px`,
      }"
    >
      {{ element.text_content }}
    </div>

    <!-- Image element content -->
    <img
      v-if="element.type === 'image' && element.image_url"
      :src="element.image_url"
      class="absolute inset-0 w-full h-full object-contain pointer-events-none"
      alt=""
    />

    <!-- Selection outline (rendered only when selected, and not in
         Preview mode — preview is "play, don't edit"). -->
    <div
      v-if="selected && !previewMode"
      class="absolute inset-0 pointer-events-none"
      style="outline: 2px solid var(--color-violet); outline-offset: 0"
    />

    <!-- Resize handles (8 total: 4 corners + 4 edge midpoints) —
         also hidden in Preview mode. -->
    <template v-if="selected && !readonly && !previewMode">
      <!-- Corners -->
      <div
        v-for="handle in ['nw', 'ne', 'sw', 'se'] as ResizeHandle[]"
        :key="handle"
        class="design-element-handle absolute"
        :class="{
          'top-0 left-0 -translate-x-1/2 -translate-y-1/2 cursor-nwse-resize': handle === 'nw',
          'top-0 right-0 translate-x-1/2 -translate-y-1/2 cursor-nesw-resize': handle === 'ne',
          'bottom-0 left-0 -translate-x-1/2 translate-y-1/2 cursor-nesw-resize': handle === 'sw',
          'bottom-0 right-0 translate-x-1/2 translate-y-1/2 cursor-nwse-resize': handle === 'se',
        }"
        :data-testid="`design-element-handle-${element.id}-${handle}`"
        @pointerdown="(e) => startDrag(e, { resize: handle })"
      />
      <!-- Edges -->
      <div
        v-for="handle in ['n', 'e', 's', 'w'] as ResizeHandle[]"
        :key="handle"
        class="design-element-handle absolute"
        :class="{
          'top-0 left-1/2 -translate-x-1/2 -translate-y-1/2 cursor-ns-resize': handle === 'n',
          'top-1/2 right-0 translate-x-1/2 -translate-y-1/2 cursor-ew-resize': handle === 'e',
          'bottom-0 left-1/2 -translate-x-1/2 translate-y-1/2 cursor-ns-resize': handle === 's',
          'top-1/2 left-0 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize': handle === 'w',
        }"
        :data-testid="`design-element-handle-${element.id}-${handle}`"
        @pointerdown="(e) => startDrag(e, { resize: handle })"
      />
    </template>
  </div>
</template>

<style scoped>
.design-element {
  /* The element itself is a CSS box; pointer events are on the
     parent div, not the inner rectangle. */
  user-select: none;
  touch-action: none;
}
.design-element.dragging {
  /* While dragging, prevent the browser from showing a text-selection
     cursor. */
  cursor: grabbing !important;
}
.design-element-handle {
  width: 8px;
  height: 8px;
  background-color: white;
  border: 1.5px solid var(--color-violet);
  border-radius: 1px;
  z-index: 10;
}
</style>
