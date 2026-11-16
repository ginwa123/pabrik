<!-- ChatScrollSlider.vue — realtime draggable scrollbar for the chat transcript.

     Continuous (not click-based): the thumb tracks the VirtualScroller's
     scroll position in realtime (scroll-up moves the thumb up, streaming
     growth moves it down) and the user can DRAG the thumb to scrub the
     chat like a native scrollbar. Coexists with UserPillRail (discrete
     click-to-jump pills); this is the proportional scrollbar visual.

     The host (ChatView) passes `getContainer`, a function returning the
     VirtualScroller's inner scroll element (or null before mount / after
     unmount). A function — not a raw element — because the scroller's
     `containerRef` resolves asynchronously after mount and swaps on chat
     switch; the slider re-resolves on an interval so it never holds a
     stale element.

     Geometry is the standard scrollbar math:
       thumbH% = clamp(clientH / scrollH * 100, MIN_THUMB_PCT, 100)
       thumbTop% = scrollTop / (scrollH - clientH) * (100 - thumbH%)
     Drag maps pointer delta back through the same ratio:
       scrollTop = startScrollTop + dY * (scrollH - clientH) / trackTravelPx
-->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { computeThumbGeometry } from './chatScrollSlider'

const props = defineProps<{
  /** Returns the live scroll element, or null when not mounted. */
  getContainer: () => HTMLElement | null
}>()

const trackRef = ref<HTMLElement | null>(null)
const thumbRef = ref<HTMLElement | null>(null)
const visible = ref(false)
const thumbHeightPct = ref(100)
const thumbTopPct = ref(0)
const scrollRatio = ref(0)
const dragging = ref(false)
const hovering = ref(false)

const ariaNow = computed(() => Math.round(scrollRatio.value * 100))

let attachedEl: HTMLElement | null = null
let rafId = 0
let resolveTimer: ReturnType<typeof setInterval> | null = null
let resizeObserver: ResizeObserver | null = null

const readAndApply = (): void => {
  const el = attachedEl ?? props.getContainer()
  if (!el) {
    visible.value = false
    return
  }
  const g = computeThumbGeometry(el.scrollTop, el.scrollHeight, el.clientHeight)
  visible.value = g.visible
  thumbHeightPct.value = g.thumbHeightPct
  thumbTopPct.value = g.thumbTopPct
  scrollRatio.value = g.ratio
}

const scheduleUpdate = (): void => {
  if (rafId) return
  rafId = requestAnimationFrame(() => {
    rafId = 0
    readAndApply()
  })
}

const onScroll = (): void => {
  scheduleUpdate()
}

const detach = (): void => {
  if (attachedEl) {
    attachedEl.removeEventListener('scroll', onScroll)
    attachedEl = null
  }
  if (resizeObserver) {
    resizeObserver.disconnect()
    resizeObserver = null
  }
}

const attach = (el: HTMLElement): void => {
  detach()
  attachedEl = el
  el.addEventListener('scroll', onScroll, { passive: true })
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(() => scheduleUpdate())
    resizeObserver.observe(el)
  }
  readAndApply()
}

/** Re-resolve the container (mount races, chat switches). */
const ensureAttached = (): void => {
  const el = props.getContainer()
  if (el !== attachedEl) {
    if (el) attach(el)
    else detach()
  } else if (el) {
    // Same element — content may have grown (streaming); refresh geometry.
    readAndApply()
  }
}

// ── Drag-to-scrub ──────────────────────────────────────────────────────
let dragStartY = 0
let dragStartScrollTop = 0
let dragScrollablePx = 0
let dragTravelPx = 1

const onThumbPointerDown = (e: PointerEvent): void => {
  const el = attachedEl ?? props.getContainer()
  if (!el || !trackRef.value || !thumbRef.value) return
  e.preventDefault()
  e.stopPropagation()
  const trackH = trackRef.value.clientHeight
  const thumbH = thumbRef.value.clientHeight
  dragTravelPx = Math.max(1, trackH - thumbH)
  dragScrollablePx = Math.max(0, el.scrollHeight - el.clientHeight)
  if (dragScrollablePx <= 0) return
  dragStartY = e.clientY
  dragStartScrollTop = el.scrollTop
  dragging.value = true
  try {
    thumbRef.value.setPointerCapture?.(e.pointerId)
  } catch {
    // jsdom / older browsers: capture unsupported, moves still tracked on thumb.
  }
}

const onThumbPointerMove = (e: PointerEvent): void => {
  if (!dragging.value) return
  const el = attachedEl ?? props.getContainer()
  if (!el) return
  e.preventDefault()
  const dY = e.clientY - dragStartY
  el.scrollTop = dragStartScrollTop + (dY * dragScrollablePx) / dragTravelPx
}

const endDrag = (): void => {
  dragging.value = false
}

/** Track click (outside the thumb) jumps — native scrollbar parity. */
const onTrackPointerDown = (e: PointerEvent): void => {
  if (e.target !== trackRef.value) return // thumb handles its own drag
  const el = attachedEl ?? props.getContainer()
  if (!el || !trackRef.value || !thumbRef.value) return
  const scrollable = el.scrollHeight - el.clientHeight
  if (scrollable <= 0) return
  const rect = trackRef.value.getBoundingClientRect()
  const clickY = e.clientY - rect.top
  const thumbPx = thumbRef.value.clientHeight
  const travel = Math.max(1, rect.height - thumbPx)
  const targetTop = Math.min(Math.max(clickY - thumbPx / 2, 0), travel)
  el.scrollTop = (targetTop / travel) * scrollable
}

/** Keyboard scrub on the focused thumb. */
const onThumbKeyDown = (e: KeyboardEvent): void => {
  const el = attachedEl ?? props.getContainer()
  if (!el) return
  const small = Math.max(40, el.clientHeight * 0.1)
  const page = Math.max(small, el.clientHeight * 0.9)
  const max = Math.max(0, el.scrollHeight - el.clientHeight)
  switch (e.key) {
    case 'ArrowUp':
      e.preventDefault()
      el.scrollTop = Math.max(0, el.scrollTop - small)
      break
    case 'ArrowDown':
      e.preventDefault()
      el.scrollTop = Math.min(max, el.scrollTop + small)
      break
    case 'PageUp':
      e.preventDefault()
      el.scrollTop = Math.max(0, el.scrollTop - page)
      break
    case 'PageDown':
      e.preventDefault()
      el.scrollTop = Math.min(max, el.scrollTop + page)
      break
    case 'Home':
      e.preventDefault()
      el.scrollTop = 0
      break
    case 'End':
      e.preventDefault()
      el.scrollTop = max
      break
  }
}

onMounted(() => {
  ensureAttached()
  // The scroller's containerRef resolves after mount and swaps on chat switch — poll until attached, then keep polling cheaply so a swap is picked up without host …
  resolveTimer = setInterval(ensureAttached, 500)
})

onBeforeUnmount(() => {
  if (rafId) cancelAnimationFrame(rafId)
  if (resolveTimer) clearInterval(resolveTimer)
  detach()
})

/** Host/test hook: force a geometry refresh. */
defineExpose({ refresh: readAndApply })
</script>

<template>
  <div
    v-show="visible"
    ref="trackRef"
    class="chat-scroll-slider"
    :class="{ 'chat-scroll-slider--active': dragging || hovering }"
    data-testid="chat-scroll-slider"
    @pointerdown="onTrackPointerDown"
    @mouseenter="hovering = true"
    @mouseleave="hovering = false"
  >
    <div
      ref="thumbRef"
      class="chat-scroll-slider__thumb"
      :class="{ 'chat-scroll-slider__thumb--dragging': dragging }"
      :style="{ height: thumbHeightPct + '%', top: thumbTopPct + '%' }"
      role="scrollbar"
      aria-orientation="vertical"
      aria-valuemin="0"
      aria-valuemax="100"
      :aria-valuenow="ariaNow"
      aria-label="Scroll chat history"
      tabindex="0"
      data-testid="chat-scroll-thumb"
      @pointerdown="onThumbPointerDown"
      @pointermove="onThumbPointerMove"
      @pointerup="endDrag"
      @pointercancel="endDrag"
      @keydown="onThumbKeyDown"
    />
  </div>
</template>

<style scoped>
.chat-scroll-slider {
  position: absolute;
  right: 2px;
  top: 8px;
  /* `--chat-composer-inset` is set by ChatView on its chat column (the
     dock's ResizeObserver measures the floating composer). The track
     stops above it so the thumb never drags behind the composer on a
     narrow viewport, where the centred composer card reaches the right
     edge. Unset anywhere else (this component's own unit tests, a bare
     host) — the fallback keeps the original 8px. */
  bottom: calc(var(--chat-composer-inset, 0px) + 8px);
  width: 12px;
  z-index: 20;
  border-radius: 999px;
  background: transparent;
  transition: background 0.15s ease;
  touch-action: none;
}

.chat-scroll-slider--active {
  background: rgb(0 0 0 / 0.08);
}

.chat-scroll-slider__thumb {
  position: absolute;
  left: 3px;
  right: 3px;
  width: auto;
  border-radius: 999px;
  background-color: var(--color-border, rgba(255, 255, 255, 0.25));
  opacity: 0.7;
  cursor: grab;
  transition:
    opacity 0.15s ease,
    background-color 0.15s ease;
}

.chat-scroll-slider:hover .chat-scroll-slider__thumb,
.chat-scroll-slider__thumb:focus-visible {
  opacity: 1;
  background-color: var(--semantic-text-dim, #888);
  outline: none;
}

.chat-scroll-slider__thumb--dragging {
  opacity: 1;
  background-color: var(--color-violet, #8b5cf6);
  cursor: grabbing;
}

@media (prefers-reduced-motion: reduce) {
  .chat-scroll-slider,
  .chat-scroll-slider__thumb {
    transition: none;
  }
}
</style>
