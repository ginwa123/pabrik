<!-- User-pill rail (2026-09-09 chatview user pill).
     Pure presentational: one pill per user group on the chat's right
     edge. Click (or Enter/Space) emits `jump` with the pill's group
     index + stable key; the host (ChatView) owns scrolling. Uniform
     vertical stack — NOT proportional to message height — so the rail
     stays predictable under VirtualScroller height estimates.

     Hovering (or keyboard-focusing) a pill opens a message box with the
     user's text, anchored to the LEFT of the pill so it reads over the
     transcript instead of off-screen. The host reserves a right gutter
     for the rail itself (see `--pill-rail-gutter` in ChatView.vue); this
     box is a transient overlay and deliberately does NOT reserve space —
     it is `pointer-events: none`, so it can never swallow a click meant
     for the message underneath it. -->
<script setup lang="ts">
import { computed, ref } from 'vue'

export interface UserPill {
  groupIndex: number
  key: string
  preview: string
}

const props = defineProps<{
  pills: UserPill[]
  activeGroupIndex: number | null
}>()

const emit = defineEmits<{
  jump: [groupIndex: number, key: string]
}>()

// Which pill's message box is open. Keyed by the pill's STABLE key (not its index) so an SSE append
// that shifts positions cannot leave the box hanging off the wrong pill — the same reason
// `jumpToUserGroup` resolves by key at click time.
const openKey = ref<string | null>(null)

const open = (key: string): void => {
  openKey.value = key
}

const close = (key: string): void => {
  // Guard on the key: `mouseleave` from the pill being LEFT can arrive
  // after `mouseenter` on the next one, and an unguarded close would
  // blank the box the user just moved to.
  if (openKey.value === key) openKey.value = null
}

// The pill the box belongs to, so the template can read its text without
// a second lookup. Null when nothing is open.
const openPill = computed((): UserPill | null => {
  if (openKey.value === null) return null
  return props.pills.find((p) => p.key === openKey.value) ?? null
})

// The open pill's position in the stack. The rail is a UNIFORM vertical
// stack (see the style block), so the index is enough to place the box
// level with its pill — no measurement, no layout thrash. -1 when closed.
const openPillIndex = computed((): number => {
  if (openKey.value === null) return -1
  return props.pills.findIndex((p) => p.key === openKey.value)
})

// Vertical centre of the open pill, measured from the rail's top edge.
const pillCentreTop = computed((): string => {
  if (openPillIndex.value < 0) return '50%'
  return `calc(var(--pill-pad) + ${openPillIndex.value} * var(--pill-pitch) + var(--pill-h) / 2)`
})
</script>

<template>
  <nav
    class="user-pill-rail"
    aria-label="Jump to user messages"
    data-testid="user-pill-rail"
    @mouseleave="openKey = null"
  >
    <button
      v-for="pill in pills"
      :key="pill.key"
      type="button"
      class="user-pill"
      :class="{ 'user-pill--active': pill.groupIndex === activeGroupIndex }"
      :aria-label="`Jump to message: ${pill.preview}`"
      data-testid="user-pill"
      @click="emit('jump', pill.groupIndex, pill.key)"
      @mouseenter="open(pill.key)"
      @mouseleave="close(pill.key)"
      @focus="open(pill.key)"
      @blur="close(pill.key)"
    />

    <!-- Message box for the hovered/focused pill. A sibling of the pills
         rather than a child of one: the rail is a 32px-wide flex column,
         and a child would be clipped to it. Anchored to the rail's right
         edge and grown leftwards, so it sits over the transcript.

         `aria-hidden` because the button's `aria-label` already carries
         the same text — announcing it twice would make a screen reader
         read every message twice while tabbing the rail. -->
    <div
      v-if="openPill"
      class="user-pill-message"
      :class="{ 'user-pill-message--active': openPill.groupIndex === activeGroupIndex }"
      :style="{ top: pillCentreTop }"
      data-testid="user-pill-message"
      aria-hidden="true"
    >
      {{ openPill.preview }}
    </div>
  </nav>
</template>

<style scoped>
.user-pill-rail {
  position: absolute;
  right: 6px;
  /* Center on the VISIBLE transcript, not the full wrapper. The wrapper
     is the full column height (the composer floats over its bottom part),
     so plain `top: 50%` sits half a composer-height too low. The dock's
     ResizeObserver publishes its height as `--chat-composer-inset` on the
     chat column (inherited here); subtracting half of it restores the
     visible center. Same contract ChatScrollSlider's track already reads.
     Falls back to plain 50% where the inset is unset (bare-host unit
     mounts, read-only peek panel with no dock). */
  top: calc(50% - var(--chat-composer-inset, 0px) / 2);
  transform: translateY(-50%);
  display: flex;
  flex-direction: column;
  /* The stack's geometry, published as custom properties so the message
     box can align itself to its pill from the same numbers (see
     `pillCentreTop`). One source of truth for the rail's rhythm. */
  --pill-h: 4px;
  --pill-gap: 8px;
  --pill-pad: 8px;
  --pill-pitch: calc(var(--pill-h) + var(--pill-gap));
  gap: var(--pill-gap);
  z-index: 20;
  padding: var(--pill-pad) 4px;
  border-radius: 999px;
}

.user-pill {
  width: 24px;
  height: var(--pill-h);
  border-radius: 999px;
  padding: 0;
  border: none;
  cursor: pointer;
  background-color: var(--color-border, rgba(255, 255, 255, 0.2));
  opacity: 0.55;
  transition:
    opacity 0.15s ease,
    transform 0.15s ease,
    background-color 0.15s ease;
}

.user-pill:hover,
.user-pill:focus-visible {
  opacity: 1;
  transform: scaleX(1.25);
  background-color: var(--semantic-text-dim, #888);
  outline: none;
}

.user-pill--active {
  opacity: 1;
  background-color: var(--color-violet, #8b5cf6);
}

/* ─── Hover/focus message box ─────────────────────────────────────────────
   Opens on hover or keyboard focus, over the transcript, level with the pill
   that summoned it: `top` is bound per-pill (see `pillCentreTop`) and the
   `-50%` on Y centres the box on that point. */

/* Anchored with `right: 100%` — 100% of the rail's OWN 32px width — so the
   box's right edge lands `margin-right` left of the pills. `right: 0` plus
   `translateX(-100%)` counted that offset twice, so the gap was `width − 24px`:
   9.7px while the box was a collapsed sliver, 256px once it had a real width. */

/* An explicit width, and this was the whole bug: with `left: auto` an
   absolutely-positioned box is shrink-to-fit and takes its available width from
   its containing block — the rail's 32px padding box — so `max-width` never
   bound and the box rendered 33.7px wide with 2 characters per line. */

/* `pointer-events: none` is load-bearing: the box overlaps real message text,
   and without it the first click on a message under an open box would hit the
   box instead. */

/* Capped at 3 lines with an ellipsis: a pill preview is 60 chars, but a pasted
   wall of text can still be long, and an unbounded box would cover half the
   transcript. */
.user-pill-message {
  position: absolute;
  right: 100%;
  transform: translateY(-50%);
  margin-right: 8px;
  width: max-content;
  max-width: 280px;
  padding: 8px 10px;
  border-radius: 8px;
  border: 1px solid var(--color-border, #282727);
  background-color: var(--semantic-card-bg, #1d1c19);
  color: var(--semantic-text, #c5c9c5);
  font-size: var(--text-dense);
  line-height: 1.45;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  pointer-events: none;
  z-index: 21;
  box-shadow: 0 8px 24px -8px rgba(0, 0, 0, 0.65);
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  overflow: hidden;
}

/* The active pill's box carries the same violet accent the pill does, so
   the highlight and the preview read as one affordance. */
.user-pill-message--active {
  border-color: var(--color-violet, #8b5cf6);
}

@media (prefers-reduced-motion: reduce) {
  .user-pill {
    transition: none;
  }
}
</style>
