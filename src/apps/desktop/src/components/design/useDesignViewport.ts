import { onMounted, onUnmounted, onUpdated, ref } from 'vue'
import type { ComputedRef, Ref } from 'vue'
import type { DesignElement } from '../../api'
import type { useDesignContextMenu } from '../../composables/useDesignContextMenu'
import { ZOOM_DEFAULT, ZOOM_MAX, ZOOM_MIN } from './designViewStorage'

type Deps = {
  effectiveItemId: ComputedRef<string>
  elements: ComputedRef<DesignElement[]>
  hasActivePage: ComputedRef<boolean>
  selectedIds: Ref<Set<string>>
  isPreviewMode: Ref<boolean>
  isSpacePressed: Ref<boolean>
  contextMenu: ReturnType<typeof useDesignContextMenu>
  readZoom: (itemId: string) => number
  writeZoom: (itemId: string, n: number) => void
}

export function useDesignViewport(deps: Deps) {
  const {
    effectiveItemId,
    elements,
    hasActivePage,
    selectedIds,
    isPreviewMode,
    isSpacePressed,
    contextMenu,
    readZoom,
    writeZoom,
  } = deps

  const ZOOM_STEP = 0.1 // each toolbar button click

  const ZOOM_WHEEL_STEP = 0.05 // each Ctrl+wheel notch (Shift = ×4)

  const zoom = ref<number>(ZOOM_DEFAULT)
  const setZoom = (next: number): void => {
    const clamped = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, next))
    // Snap to nearest 1% so the displayed percentage is clean.
    const snapped = Math.round(clamped * 100) / 100
    zoom.value = snapped
    if (effectiveItemId.value) writeZoom(effectiveItemId.value, snapped)
  }
  const zoomIn = (): void => setZoom(zoom.value + ZOOM_STEP)
  const zoomOut = (): void => setZoom(zoom.value - ZOOM_STEP)
  const zoomReset = (): void => setZoom(1.0)

  // Fit-to-viewport: compute the zoom level that makes the union bbox of all elements fit inside the
  // scroll container with a small margin, then scroll the container so the elements appear centered.
  // Mirrors Figma's Shift+1 ("Zoom to fit").
  const ZOOM_FIT_MARGIN = 48 // px of padding around the fitted canvas
  const ZOOM_FIT_DEFAULT_W = 1440
  const ZOOM_FIT_DEFAULT_H = 1024

  const zoomFit = (): void => {
    if (!hasActivePage.value) return
    const container = document.querySelector<HTMLElement>(
      '[data-testid="design-canvas-scroll-container"]',
    )
    if (!container) return
    const cw = container.clientWidth - ZOOM_FIT_MARGIN
    const ch = container.clientHeight - ZOOM_FIT_MARGIN
    if (cw <= 0 || ch <= 0) return

    // Union bbox of elements (or default if none).
    let minX = 0
    let minY = 0
    let contentW = ZOOM_FIT_DEFAULT_W
    let contentH = ZOOM_FIT_DEFAULT_H
    if (elements.value.length > 0) {
      minX = Math.min(...elements.value.map((e) => e.x))
      minY = Math.min(...elements.value.map((e) => e.y))
      const maxX = Math.max(...elements.value.map((e) => e.x + e.width))
      const maxY = Math.max(...elements.value.map((e) => e.y + e.height))
      contentW = maxX - minX
      contentH = maxY - minY
    }

    const zoomX = cw / contentW
    const zoomY = ch / contentH
    const fit = Math.min(zoomX, zoomY)
    setZoom(fit)
    // Center after the scale change so the elements appear centered. The scroll math mirrors the
    // Ctrl+wheel handler, but offset by the elements' minX/minY (the canvas div is auto-grown to wrap
    // elements, so the scroll origin is the bbox top-left, not 0,0).
    requestAnimationFrame(() => {
      const scaledW = contentW * zoom.value
      const scaledH = contentH * zoom.value
      container.scrollLeft = minX * zoom.value + (scaledW - container.clientWidth) / 2
      container.scrollTop = minY * zoom.value + (scaledH - container.clientHeight) / 2
    })
  }


  interface PinchPointer {
    startX: number
    startY: number
    currentX: number
    currentY: number
  }

  const pinchPointers = new Map<number, PinchPointer>()
  let pinchStartDistance: number | null = null
  let pinchStartZoom: number | null = null

  const onPinchPointerDown = (event: PointerEvent): void => {
    // Run the Space-pan handler first — it's a no-op when Space isn't held, and we want both gestures
    // to coexist on the same element (chained instead of multiple @pointerdown listeners because Vue
    // 3 templates only bind one listener per event per element).
    startCanvasPan(event)
    // Mouse can't pinch (single-pointer by definition). Pen / touch only.
    if (event.pointerType === 'mouse') return
    // Don't pinch-zoom when pinching on a design element — let the
    // element's own pointerdown handler take the gesture for drag.
    const targetEl = event.target as HTMLElement | null
    if (targetEl?.closest('[data-design-element]')) return
    const target = event.currentTarget as HTMLElement | null
    if (!target) return
    target.setPointerCapture(event.pointerId)
    pinchPointers.set(event.pointerId, {
      startX: event.clientX,
      startY: event.clientY,
      currentX: event.clientX,
      currentY: event.clientY,
    })
    if (pinchPointers.size === 2) {
      const [p1, p2] = [...pinchPointers.values()] as [PinchPointer, PinchPointer]
      pinchStartDistance = Math.hypot(p2.startX - p1.startX, p2.startY - p1.startY)
      pinchStartZoom = zoom.value
    }
  }

  const onPinchPointerMove = (event: PointerEvent): void => {
    const p = pinchPointers.get(event.pointerId)
    if (!p) return
    p.currentX = event.clientX
    p.currentY = event.clientY
    if (pinchPointers.size < 2 || pinchStartDistance == null || pinchStartZoom == null) return
    // Two fingers starting at the same point gives distance=0; division
    // would explode. Treat as no-op until the user actually moves a finger.
    if (pinchStartDistance <= 0) return
    const [p1, p2] = [...pinchPointers.values()] as [PinchPointer, PinchPointer]
    const currentDistance = Math.hypot(p2.currentX - p1.currentX, p2.currentY - p1.currentY)
    const ratio = currentDistance / pinchStartDistance
    const newZoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, pinchStartZoom * ratio))
    setZoom(newZoom)
  }

  const onPinchPointerEnd = (event: PointerEvent): void => {
    pinchPointers.delete(event.pointerId)
    const target = event.currentTarget as HTMLElement | null
    if (target && target.hasPointerCapture(event.pointerId)) {
      target.releasePointerCapture(event.pointerId)
    }
    if (pinchPointers.size < 2) {
      pinchStartDistance = null
      pinchStartZoom = null
    }
  }

  // Ctrl+wheel zooms in/out at the cursor position. The plain wheel
  // is left alone (it scrolls the canvas container as usual — matches
  // Figma / Miro / VS Code). Shift wheel zooms ×4 faster.
  const handleCanvasWheel = (event: WheelEvent): void => {
    if (!event.ctrlKey && !event.metaKey) return
    event.preventDefault()
    const direction = event.deltaY < 0 ? 1 : -1
    const speed = event.shiftKey ? 4 : 1
    const next = zoom.value + direction * ZOOM_WHEEL_STEP * speed

    // Anchor the zoom at the cursor position so zoom-in feels natural (the point under the cursor
    // stays under the cursor after the scale).
    const container = event.currentTarget as HTMLElement | null
    if (!container) {
      setZoom(next)
      return
    }
    const rect = container.getBoundingClientRect()
    const cursorX = event.clientX - rect.left + container.scrollLeft
    const cursorY = event.clientY - rect.top + container.scrollTop
    const before = zoom.value
    setZoom(next)
    const after = zoom.value
    if (before === after) return
    const ratio = after / before
    container.scrollLeft = cursorX * ratio - (event.clientX - rect.left)
    container.scrollTop = cursorY * ratio - (event.clientY - rect.top)
  }

  // Restore zoom on design-item change (different localStorage key). Mount covers the initial item
  // (the parent keys this component by item id, so item switches remount); the prev-id guard covers
  // itemId prop changes on a reused instance.
  const prevZoomItemId = ref(effectiveItemId.value)
  onMounted(() => {
    prevZoomItemId.value = effectiveItemId.value
    zoom.value = effectiveItemId.value ? readZoom(effectiveItemId.value) : ZOOM_DEFAULT
  })
  onUpdated(() => {
    if (effectiveItemId.value !== prevZoomItemId.value) {
      prevZoomItemId.value = effectiveItemId.value
      zoom.value = effectiveItemId.value ? readZoom(effectiveItemId.value) : ZOOM_DEFAULT
    }
  })

  // ─── Handlers ──────────────────────────────────────────────────────────
  const handleCanvasClick = (event: MouseEvent): void => {
    // In Preview mode, canvas clicks are user-typed values inside iframes or pan gestures — neither
    // should clear the selection.
    if (isPreviewMode.value) return
    // If we just finished a pan-drag (Space + drag), swallow the click so it doesn't deselect the
    // active element. The browser dispatches a synthetic click after pointerup; without this guard,
    // every pan ends with selection-clear.
    if (isPanning.value) return
    // Only clear selection when clicking the canvas itself (not an element child). The DesignElement
    // child events fire before this and they stopPropagation on their pointerdown — so this handler
    // is only called for the canvas background.
    if ((event.target as HTMLElement | null)?.closest('[data-design-element]')) {
      return
    }
    selectedIds.value = new Set()
  }

  // Chunk 3 (right-click group menu plan): per-instance context menu
  // for canvas right-clicks. Preview mode silently ignores right-clicks
  // (Figma parity: the menu is editor-only).
  function handleCanvasContextMenu(event: MouseEvent): void {
    if (isPreviewMode.value) return
    // Open with the current selection — right-click on empty canvas acts on whatever was previously
    // selected. The LayersPanel owns its own context-menu instance for row-level right-clicks; this
    // one is canvas-only.
    contextMenu.open(event, Array.from(selectedIds.value))
  }

  // True while the user is mid-drag with Space held. Gates the
  // canvas-click deselection guard above.
  const isPanning = ref(false)

  // Pointer-drag pan. Fires on the canvas scroll container; only does anything when Space is held.
  const startCanvasPan = (event: PointerEvent): void => {
    if (!isSpacePressed.value) return
    // Primary button only — middle / right clicks do different things
    // (autoscroll, context menu) on some browsers.
    if (event.button !== 0) return
    const target = event.currentTarget as HTMLElement | null
    if (!target) return
    target.setPointerCapture(event.pointerId)
    isPanning.value = true
    document.body.style.cursor = 'grabbing'

    // Snapshot the scroll position + pointer position at drag start.
    // The move handler subtracts the cursor delta from the original
    // scroll position so the canvas appears to follow the cursor.
    const startScrollLeft = target.scrollLeft
    const startScrollTop = target.scrollTop
    const startClientX = event.clientX
    const startClientY = event.clientY

    const onMove = (e: PointerEvent): void => {
      // cursor delta in screen-px = scroll delta in scroll-px
      // (no zoom division needed — scrollLeft / scrollTop are in
      // unscaled coords; the inner div's scale() does not affect them).
      const dx = e.clientX - startClientX
      const dy = e.clientY - startClientY
      target.scrollLeft = startScrollLeft - dx
      target.scrollTop = startScrollTop - dy
    }
    const onUp = (e: PointerEvent): void => {
      if (target.hasPointerCapture(e.pointerId)) {
        target.releasePointerCapture(e.pointerId)
      }
      isPanning.value = false
      // Restore grab cursor only if Space is still held; otherwise
      // clear back to the default cursor.
      document.body.style.cursor = isSpacePressed.value ? 'grab' : ''
      target.removeEventListener('pointermove', onMove)
      target.removeEventListener('pointerup', onUp)
      target.removeEventListener('pointercancel', onUp)
    }
    target.addEventListener('pointermove', onMove)
    target.addEventListener('pointerup', onUp)
    target.addEventListener('pointercancel', onUp)
  }

  onUnmounted(() => {
    // Clear pinch-zoom state — if pointers are still active (rare,
    // but possible across the chat-toggle unmount/mount cycle), the
    // next mount would otherwise see stale entries.
    pinchPointers.clear()
    pinchStartDistance = null
    pinchStartZoom = null
  })

  return {
    zoom,
    zoomIn,
    zoomOut,
    zoomReset,
    zoomFit,
    handleCanvasClick,
    handleCanvasContextMenu,
    onPinchPointerDown,
    onPinchPointerMove,
    onPinchPointerEnd,
    handleCanvasWheel,
  }
}
