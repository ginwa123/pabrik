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
    // Single-element shortcut (kept for backward compat with tests + simple use cases). True iff
    // `selectedIds` has exactly this element and nothing else. The wrapper's `.selected` class is
    // applied iff this is true OR the element is in a multi-selection that includes it.
    selected?: boolean
    // The full selection set (Figma multi-select model). When non-empty AND this element's id is in
    // it, render the violet outline + resize handles. When only `selected === true` (no
    // multi-selection context), the wrapper renders the legacy single-selection chrome.
    selectedIds?: string[]
    readonly?: boolean
    // Current canvas zoom level (1.0 = 100%). When the canvas is CSS-scaled via `transform:
    // scale(zoom)`, the cursor delta (screen-px) and the model's element coordinates (design-px)
    // differ — drag/resize math divides by zoom to keep them aligned.
    zoom?: number
    // IDs needed to lazy-load the element's HTML body from the backend (the page+elements GET
    // response excludes the body to keep payloads small). Defaults are empty so the component can
    // mount without them; fetchHtml is a no-op when any is missing.
    workspaceId?: string
    itemId?: string
    pageId?: string
    // When true, the parent canvas is in Preview/Edit mode (toggle
    // in the canvas header bar). In Preview:
    //   - the inner iframe gets `pointer-events: auto` so the user
    //     can type into `<input>` elements, click buttons, etc.
    //   - the wrapper div suppresses its drag handler
    //   - the selection chrome (resize handles, outline) is hidden
    //     even when `selected === true` — preview is "play, don't edit"
    // Default false (the canvas's normal edit mode).
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
  // Chunk 3: select now carries an `additive` flag so the canvas's
  // Shift+click can toggle membership in the multi-selection Set
  // (Figma parity with the layers panel which already supports it).
  select: [payload: { elementId: string; additive: boolean }]
  /** DEPRECATED — replaced by `translate` (move) and `resize` (Figma parity with the backend's POST
   * /translate + POST /resize split — see
   * `docs/superpowers/plans/2026-08-06-split-move-resize.md`). */
  /** Kept for back-compat; new callers MUST emit the typed events. */
  update: [patch: Partial<DesignElement>]
  /** NEW (2026-08-06) — fires on every pointermove during a drag for a SINGLE element (leaf OR a
   * single-element drag of a group that didn't trigger the group-drag path). */
  /** Payload is the CURSOR DELTA `(dx, dy)` in design-px PLUS the source element's id — the parent
   * is responsible for adding the delta to the element's start position before calling
   * `workspacesStore.translateDesignElement`. */
  /** The `elementId` was added 2026-08-06 (post-#162 fix) because the single-element drag wire
   * previously relied on `selectedIds.size === 1` to identify the dragged element. */
  /** That check is fragile: if the user shift-clicked to deselect (toggling removed the dragged
   * id), or if a multi-select from earlier wasn't cleared, the parent's `handleElementTranslate`
   * bailed early — the element never moved. */
  /** Carrying the id in the event makes the wire self-contained. Replaces `update` for the move use
   * case. */
  translate: [payload: { elementId: string; dx: number; dy: number }]
  /** NEW (2026-08-06) — fires on every pointermove during a RESIZE gesture (dragging one of the 8
   * resize handles). Payload carries the absolute target `(x, y, width, height, rotation)` after
   * applying the cursor delta to the start geometry. */
  /** Parent calls `workspacesStore.resizeDesignElement` with this absolute patch. Replaces `update`
   * for the resize use case. */
  resize: [patch: Partial<DesignElement>]
  // Chunk 2: when the user drags an element that's part of a multi-selection, the WHOLE selection
  // moves. The parent (DesignView) applies the dx/dy to every selected element's start position;
  // this component only reports the cursor delta.
  // The parent calls workspacesStore.moveDesignElementsBatch (or the AppLayout handler) on each
  // element.
  groupDrag: [delta: { dx: number; dy: number }]
  // Chunk 3: emit on drag-end (pointerup or pointercancel) so the
  // parent can clear its snap guides. Fires after both the single-
  // element drag and the multi-selection group drag paths.
  dragEnd: []
  // Undo/redo plan: emit on drag-start so the parent can capture pre-state for the eventual undo
  // entry. Carries the moved ids so the parent can capture the full selection (not just this
  // element).
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
  // Inline opacity; the backend's `opacity` field defaults to 1.0
  // and the v-if on the parent only renders elements with valid
  // geometry, so no extra defensive checks needed.
  opacity: props.element.opacity,
  // FIX 2026-08-06 (task_1785988530202): apply `z-index` inline so
  // CSS handles the z-axis stacking. Without this, the right-click
  // reorder menu (Bring to front / forward / Send backward / back) and
  // the Ctrl+]/[ keyboard shortcuts WERE updating the DB
  // `z_index` values correctly but the canvas visual stacking didn't
  // change — because for `position: absolute` elements without an
  // explicit `z-index` CSS, DOM order = visual stacking; and the
  // frontend's `reorderDesignElements` mirrors the response IN-PLACE
  // (preserves array order), so the DOM order doesn't change either.
  // Net: z_index changed in DB but the canvas looked identical.
  // The fix is the single line below — CSS does the rest.
  zIndex: props.element.z_index,
  // Selection outline is rendered as a child absolutely-positioned
  // div via the .selected class below; the parent keeps the
  // standard border styling from the element itself.
}))

// ─── Drag (move) ────────────────────────────────────────────────────────

type DragMode = 'move' | { resize: ResizeHandle }

type ResizeHandle = 'nw' | 'n' | 'ne' | 'w' | 'e' | 'sw' | 's' | 'se'

const isDragging = ref(false)

// Workspace store — used to look up the parent element by id when
// the user clicks on a child. The store is the canonical source of
// page elements (mirrored from the backend's `design_elements` array).
const workspacesStore = useWorkspacesStore()

// True when this element is nested inside a parent group/frame. The backend's `COALESCE(parent_id,
// '')` returns '' for top-level rows, non-empty for nested rows. Legacy / pre-migration shapes may
// return `null` or `undefined` — both are treated as top-level so legacy elements remain draggable.
const isChildOfGroup = computed(() => {
  const pid = props.element.parent_id
  return !!pid && pid !== ''
})

// The immediate parent element, looked up from the workspace store's
// `item.design_elements[]` array (the mirrored backend payload). Null
// when:
//   - the element is top-level (parent_id is empty/null/undefined)
//   - the required ids (workspaceId/itemId) are missing from props
//   - the store doesn't have the workspace/item loaded
//   - the parent can't be found in the elements array (orphan row)
//
// The reactivity means the parent is re-resolved when the page's elements array changes (e.g. SSE
// `design_element_created` adds the parent that this child references). For the common case (the
// canvas is open + elements are fetched), the parent is found on the first click.
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
  // The 8 resize handles are children of the .design-element wrapper. The wrapper also has a
  // @pointerdown handler (for 'move'). Without stopping propagation, clicking a handle would bubble
  // to the wrapper and start TWO gestures: the resize (on the handle) and a move (on the wrapper).
  // The wrapper's setPointerCapture then steals capture from the handle — the W3C Pointer Events
  // spec says most recent setPointerCapture wins — leaving the resize handler starved and the move
  // handler running instead. Result: the element MOVES instead of resizing.
  // Symptom: "design mode, when user want to resize the element move too". Fix: stopPropagation on
  // any non-'move' gesture.
  // The check runs before the readonly/previewMode/button early-returns so even an early-returning
  // handle click doesn't bubble (defensive — the bubble decision is independent of gesture
  // eligibility).
  // The canvas's @contextmenu (right-click menu) is a separate event and unaffected by pointerdown
  // propagation, so right-click handling still works.
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
  // In Preview mode, the canvas is "playing" the mockup — clicks
  // on element bodies are absorbed by the inner iframe (typed text,
  // button activations). Don't start a drag, don't emit select.
  if (props.previewMode) {
    designLogger.debug({
      reason: 'drag:noop:preview',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    return
  }
  // Don't initiate a drag if the click was on an interactive child
  // (e.g. the iframe content) — pointer-events:none on the iframe
  // already prevents that, but we double-check.
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
  // User request (2026-08-06, follow-up to drag-suppress): clicking
  // on a child element should select the parent group, not the child
  // itself. The user wants to interact with the GROUP layer (drag
  // the whole subtree, edit group properties), not the child row.
  // Without this redirect, the user must click the parent header
  // separately — a two-step flow that's easy to miss.
  //
  // Shift+click keeps the existing toggle behaviour (toggle the
  // CHILD in the multi-selection). For Shift+click we want the
  // child in the multi-select, not the parent — the user's intent
  // is "operate on this child", not "select its parent group".
  //
  // Falls back to selecting the child itself when:
  //   - the parent can't be looked up (orphan child, store not
  //     loaded, missing ids) — safe-degrade to the old behaviour
  //   - shift+click (additive select)
  //   - top-level element (parent_id is empty/null/undefined)
  //
  // Placement: this is the SELECT resolution. The drag-suppress
  // guard below still fires for child pointer-drags (the user has
  // to click on the parent's bounding box after the redirect to
  // initiate a drag; the redirect is purely a selection concern).
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

  // ─── Child-of-group: block single-element move drag ───────────────── User request (2026-08-06,
  // drag-on-child-element bug): a child element nested inside a parent group/frame should NOT be
  // independently movable.
  // The selection still fires (the `emit('select', ...)` above) so the user can edit the child's
  // properties in the side panel, but the pointer-drag is suppressed.
  // To move the row, the user must click on the parent group/frame's bounding box (the body of the
  // group's element, which in the LayersPanel is the row immediately above the children).
  // Placement: BEFORE dragStart so the parent's undo-state capture doesn't fire for a gesture that
  // will never happen.
  // The multi- select exception preserves the existing behaviour where a multi-child selection can
  // still move (the triggerGroupDrag branch below would handle it via groupDrag — child-drag is the
  // only mode suppressed). Exception: `mode === 'move'` only.
  // Resize handles still work on the child (Figma parity — child resize is independent, only child
  // move is blocked).
  const inMultiSelect = props.selectedIds.length > 1 && props.selectedIds.includes(props.element.id)
  if (mode === 'move' && isChildOfGroup.value && !inMultiSelect) {
    designLogger.debug({
      reason: 'drag:noop:child-of-group',
      caller: 'DesignElement.startDrag',
      element: abbrevElement(props.element),
    })
    return
  }

  // Undo/redo plan (Chunk 4): emit drag-start BEFORE the gesture branches so the parent can capture
  // pre-state. For single-element drag, the captured set is [this element]. For group drag (below),
  // we re-emit with the full selection BEFORE setting up the move handler.
  // This way the parent's pre-state read happens once.
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

  // Group drag (Chunk 2): when this element is part of a multi-selection, dragging moves the ENTIRE
  // selection. The parent applies the same dx/dy to every selected element's start position.
  // Resize is per-element only (no group resize makes sense — the user would expect to resize only
  // the element under the cursor).
  // NEW (group-drag fix): also fire groupDrag when the element is a `group` or `frame` AND the user
  // is dragging just the group (not a multi-selection that contains it). The parent expands groups
  // transitively (drag-moves the whole subtree — Figma parity).
  // For non-group elements in a single-element selection, the drag stays per-element (no
  // behavioural change).
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
    // BUG FIX (2026-08-06, design-mode-moves-so-fast v2): send
    // INCREMENTAL dx/dy (delta since last emit), NOT the cumulative
    // cursor distance from drag-start. The wire `dx` is interpreted by
    // the backend as "set x = x + dx" (UPDATE x = x + ?), so the
    // previous wire — which sent `dx = e.clientX - startClientX` per
    // tick — caused the server to compound: after N ticks of cursor
    // movement d, the element ends up at d·N·(N+1)/2 instead of d.
    // A 100px drag in 20 ticks landed the element at ~1050 design-px.
    //
    // Tracking the last-emitted value (initialised to 0 at drag start)
    // makes the wire send exactly the delta since the previous emit,
    // including the trailing pointerup emit. Server still ADDS, but
    // the cumulative effect is now `d·1 + d·1 + ... + d·1 = d·N`,
    // which is what the cursor moved.
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
        // INCREMENTAL delta — server ADDs this to the current
        // position. End-of-drag total = cumulative cursor delta.
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
      // Trailing emit: capture the final position regardless of throttle. Use INCREMENTAL delta so
      // the server's last ADD lands exactly on the cursor's end position. Without this the trailing
      // emit would re-apply the FULL cumulative (compounding again).
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

  // ─── Single-element drag path log ────────────────────────────────── The triggerGroupDrag branch
  // above already returned for groups / frames / multi-select. Falls through here for leaves
  // (rectangle, ellipse, text, image).
  // The "drag:start:move" line below is what proves the leaf element actually started a drag —
  // without it, "I clicked but nothing moved" can't be localised.
  designLogger.info({
    reason: 'drag:start:move',
    caller: 'DesignElement.startDrag',
    element: abbrevElement(props.element),
    isGroup: false,
    startClientX: event.clientX,
    startClientY: event.clientY,
  })

  // Single-element drag. 50 ms leading-edge throttle + trailing
  // pointerup emit. The visual position update flows through:
  //   pointermove (60 Hz) → 50 ms throttle → emit('update') →
  //   useDesignHandlers.updateElement → workspacesStore.updateDesignElementGeometry
  //   (PATCH) → mirrors the response into item.design_elements[] →
  //   props.element.x/y updates reactively → elementStyle.left/top
  //   moves on the next frame → user sees the drag follow the cursor.
  //
  // The backend's SSE `design_element_updated` event arrives after
  // the PATCH. The frontend designSse.ts handler SKIPS
  // fetchDesignElements (the SSE dedupe Map sees this is a local
  // mutation within the 1500 ms TTL). So the mirror step above is
  // the source of truth for the visual position — without it, the
  // element would stay frozen at its pointerdown-time position for
  // the entire drag (the bug fixed on 2026-08-06 — the old comment
  // below incorrectly claimed the PATCH round-trip updated local
  // state).
  //
  // The throttle keeps the PATCH rate at ≤20 Hz (server load).
  // The SSE dedupe removes the GET fan-out that would otherwise
  // dominate backend cost.
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
  // Overwrite the drag:start:move info above with a more-specific reason (resize vs move) using
  // `mode`. The earlier info line is a redundancy safety net in case this code path throws before
  // reaching here.
  designLogger.info({
    reason: mode === 'move' ? 'drag:start:move' : 'drag:start:resize',
    caller: 'DesignElement.startDrag',
    element: abbrevElement(props.element),
    isGroup: false,
    startClientX: startX,
    startClientY: startY,
    extra: { mode: typeof mode === 'string' ? mode : mode.resize },
  })

  // The latest pending event we intend to emit. Throttled: we only emit when either (a) 50ms has
  // elapsed since the last emit, or (b) pointerup fires (the trailing emit captures the final
  // position even if the throttle window hasn't elapsed).
  // For mode='move' we emit `translate` with the INCREMENTAL cursor delta (delta since the last
  // emit) — the parent adds it to the current server position via
  // `workspacesStore.translateDesignElement` (POST /translate).
  // The backend handles the cascade for groups. BUG FIX (2026-08-06, design-mode-moves-so-fast v2):
  // the wire used to carry the CUMULATIVE cursor delta from drag-start (`dx = e.clientX - startX`).
  // The backend interprets `dx` as "set x = x + dx", so each throttled emit compounded: after N
  // ticks the element landed at d·N·(N+1)/2 design-px instead of d.
  // Tracking lastEmittedDx and sending the delta since the last emit makes the cumulative effect =
  // d·1·N = d·N, which is what the cursor moved. Same fix as the group-drag branch above.
  // For mode='resize' we emit `resize` with the absolute target patch — the parent calls
  // `workspacesStore.resizeDesignElement` (POST /resize). Resize never cascades.
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
      // Carry the source elementId in the event so the parent doesn't
      // have to fish it out of `selectedIds` (which can be wrong —
      // see the doc on the `translate` emit type).
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
    // Narrowing: at this point `mode` must be the `{ resize: ResizeHandle }`
    // variant because the `if (mode === 'move')` branch above returned.
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

// ─── HTML preview wrapper ─────────────────────────────────────────────── ─── HTML preview wrapper
// ─────────────────────────────────────────────── Lazy-load the element's stored HTML body so the
// canvas can render the actual design (not just a placeholder rectangle).
// The body is excluded from the page+elements GET response to keep payloads small for designs with
// many elements, so we fetch per-element here.
// Re-fetch when the element changes (different id), the file_path changes (the user updated the
// HTML via Monaco), or the file's updated_at changes (the user re-saved via Monaco without changing
// the path).
const htmlBody = ref<string>('')
const htmlLoadError = ref<string | null>(null)
const isLoadingHtml = ref(false)
let htmlFetchSeq = 0

const fetchHtml = async (): Promise<void> => {
  // No file_path = no HTML body to render. This is the common case
  // for legacy / empty elements created before the body feature.
  if (!props.element.file_path) {
    htmlBody.value = ''
    htmlLoadError.value = null
    isLoadingHtml.value = false
    return
  }
  // Need the full id tuple to call the API; the parent's `fetchDesignElements`
  // call doesn't carry them through to here yet, so guard gracefully.
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
    // Only commit the result if this is still the latest in-flight
    // request; otherwise a stale fetch could clobber newer content.
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

// Re-fetch when the element identity, file path, or updated_at changes. `updated_at` is the proxy
// for "the user re-saved the HTML via Monaco in the PropertiesPanel" — the path stays the same but
// the file content changed.
// Prev-combo guard on update instead of a watcher; mount above covers the initial fetch.
const prevHtmlKey = ref('')
const htmlKey = () => `${props.element.id}|${props.element.file_path}|${props.element.updated_at}`
onUpdated(() => {
  const key = htmlKey()
  if (key !== prevHtmlKey.value) {
    prevHtmlKey.value = key
    void fetchHtml()
  }
})

// ─── Delete (Delete/Backspace key on the selected element) ────────────── We don't bind window
// keydown here (the parent DesignView owns keyboard events); the parent emits `delete` on the
// active element.
// A global keydown listener attached at mount below handles the `Delete` key when this element is
// selected (gated on selection inside handleKeydown). Actually — we DO bind a window listener when
// selected so the user can hit Delete without the canvas having to know.
// Cleaner UX than routing it through DesignView.
import { onUnmounted } from 'vue'

const handleKeydown = (e: KeyboardEvent): void => {
  // Chunk 2: gate on the full selection set, not just this element's `selected` flag. When the user
  // has multi-selected several elements via Shift+click, hitting Delete should remove ALL of them —
  // even though only ONE of them is the "active" one with `selected: true`.
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
  // Emit one `delete` per selected id. When only the legacy `selected`
  // flag is set (no multi-selection context), fall back to deleting
  // just this element so the back-compat path still works.
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
