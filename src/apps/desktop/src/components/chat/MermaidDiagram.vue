<script setup lang="ts">
/** MermaidDiagram — one `<mermaid>…</mermaid>` block of an assistant turn, drawn as SVG. Owns no
 * palette: `helpers/mermaid.ts` reads the app's CSS variables. What it does own is the redraw after
 * a theme flip, because the SVG carries a scoped stylesheet of literal colours. */
import { computed, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import DiagramViewer from './DiagramViewer.vue'
import { inlineDiagramLayout, parseDiagramSize } from '../../helpers/diagramViewport'
import type { DiagramSize } from '../../helpers/diagramViewport'
import { renderMermaid } from '../../helpers/mermaid'
import { onThemeApplied, themeRevision } from '../../theme/runtime'

const props = defineProps<{ source: string }>()

const svg = ref('')
const failure = ref('')
const copied = ref(false)
const preview = ref(false)
const frame = ref<HTMLElement | null>(null)
const available = ref(0)

// The source AND the theme revision this component has already asked for. `onUpdated` fires on ANY
// parent re-render (a streaming sibling, a scroll), so the draw is keyed on both: a theme flip has to
// rebuild the SVG, whose scoped stylesheet holds literal colours.
let drawn = ''
// Token so a slow render cannot overwrite the result of a newer one.
let token = 0
let copyTimer: ReturnType<typeof setTimeout> | null = null
let offThemeApplied: (() => void) | null = null

const draw = (): void => {
  const key = `${themeRevision.value}\u0000${props.source}`
  if (drawn === key) return
  drawn = key
  const mine = ++token
  svg.value = ''
  failure.value = ''
  renderMermaid(props.source)
    .then((markup) => {
      if (mine === token) svg.value = markup
    })
    .catch((cause: unknown) => {
      if (mine !== token) return
      failure.value = cause instanceof Error ? cause.message : String(cause)
    })
}

/** The column the drawing has to live in. A block's own width is only knowable after layout, so it
 * is read on every update — `available` only re-renders when the number actually changed. */
const measure = (): void => {
  available.value = frame.value?.clientWidth ?? 0
}

onMounted(() => {
  draw()
  offThemeApplied = onThemeApplied(draw)
  measure()
})
onUpdated(() => {
  draw()
  measure()
})

const natural = computed<DiagramSize | null>(() => parseDiagramSize(svg.value))
const layout = computed(() => inlineDiagramLayout(natural.value, available.value))
/** Never upscale, never shrink past `MIN_INLINE_SCALE` — the frame scrolls the rest. */
const zoomStyle = computed(() =>
  layout.value ? { width: `${layout.value.width}px` } : undefined,
)

// A Mermaid parse error is a multi-line dump with the offending source line in it; the first line
// names the problem, and the source underneath is already the rest of the answer.
const failureLine = computed(() => {
  const first = failure.value.split('\n')[0]?.trim() ?? ''
  return first.length > 200 ? `${first.slice(0, 200)}…` : first
})

const copySource = (event?: MouseEvent): void => {
  event?.stopPropagation()
  void navigator.clipboard
    .writeText(props.source)
    .then(() => {
      copied.value = true
      if (copyTimer) clearTimeout(copyTimer)
      copyTimer = setTimeout(() => {
        copied.value = false
      }, 1600)
    })
    .catch(() => {
      // No clipboard permission: leave the button in its idle state rather than claim success.
      copied.value = false
    })
}

onBeforeUnmount(() => {
  offThemeApplied?.()
  offThemeApplied = null
  if (copyTimer) clearTimeout(copyTimer)
})
</script>

<template>
  <figure ref="frame" class="chat-mermaid" data-testid="chat-mermaid">
    <div v-if="svg" class="chat-mermaid-canvas">
      <button
        type="button"
        class="chat-mermaid-zoom"
        :style="zoomStyle"
        title="Click to enlarge"
        aria-label="Enlarge diagram"
        data-testid="chat-mermaid-enlarge"
        @click="preview = true"
      >
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span class="chat-mermaid-svg" data-testid="chat-mermaid-svg" v-html="svg"></span>
      </button>
      <button
        type="button"
        class="chat-mermaid-copy"
        :class="{ 'chat-mermaid-copy--done': copied }"
        :title="copied ? 'Copied' : 'Copy Mermaid source'"
        :aria-label="copied ? 'Copied' : 'Copy Mermaid source'"
        data-testid="chat-mermaid-copy"
        @click="copySource"
      >
        <UiIcon name="clipboard" size-class="w-3.5 h-3.5" />
      </button>
    </div>
    <template v-else>
      <figcaption v-if="failureLine" class="chat-mermaid-note" data-testid="chat-mermaid-error">
        Diagram not rendered — {{ failureLine }}
      </figcaption>
      <pre class="chat-mermaid-source"><code>{{ source }}</code></pre>
    </template>

    <figcaption v-if="layout?.overflow" class="chat-mermaid-wide" data-testid="chat-mermaid-wide">
      Wider than this column — scroll across, or open it to zoom.
    </figcaption>

    <DiagramViewer
      :open="preview"
      label="Mermaid diagram"
      :natural="natural"
      @close="preview = false"
    >
      <div class="chat-mermaid-viewer-svg" v-html="svg"></div>
    </DiagramViewer>
  </figure>
</template>

<style scoped>
.chat-mermaid {
  position: relative;
  display: block;
  margin: 0;
  /* Same frame chrome as ChatView's `.chat-html-frame` — border, radius and surface — so an html
     block and a diagram read as one family. Padding is this component's own: the frame's inner
     document supplied its own margins. */
  padding: 12px;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
}

/* The scroll container, not the frame: a drawing wider than the column keeps its legible width and
   scrolls here, with a visible thin scrollbar so the overflow is discoverable. */
.chat-mermaid-canvas {
  max-height: 70vh;
  overflow: auto;
  scrollbar-color: var(--color-gray-3, #7a8382) transparent;
  scrollbar-width: thin;
}

.chat-mermaid-canvas::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}

.chat-mermaid-canvas::-webkit-scrollbar-thumb {
  border-radius: 4px;
  background: var(--color-gray-3, #7a8382);
}

/* The whole drawing is the hit target: a real <button>, so Enter/Space work and the browser
   announces it, with the diagram's own pointer as the affordance. */
.chat-mermaid-zoom {
  display: block;
  min-width: 100%;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  text-align: center;
  cursor: zoom-in;
}

.chat-mermaid-zoom :deep(svg) {
  display: block;
  margin: 0 auto;
  max-width: 100%;
  height: auto;
}

.chat-mermaid-zoom:focus-visible {
  outline: 1px solid var(--semantic-link, #8ba4b0);
  outline-offset: 4px;
  border-radius: 4px;
}

.chat-mermaid-wide {
  margin-top: 8px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: 0.75rem;
}

/* Copy chrome sits over the diagram, not in the flow: it appears on hover or keyboard focus, and
   stays put once used so the "copied" state is readable. */
.chat-mermaid-copy {
  position: absolute;
  top: 6px;
  right: 6px;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  padding: 0;
  border: 1px solid var(--color-border, #282727);
  border-radius: 6px;
  background: var(--color-bg-p1, #282727);
  color: var(--semantic-text-muted, #a6a69c);
  cursor: pointer;
  opacity: 0;
  transition:
    opacity 0.12s ease,
    color 0.12s ease,
    border-color 0.12s ease;
}

.chat-mermaid:hover .chat-mermaid-copy,
.chat-mermaid-copy:focus-visible,
.chat-mermaid-copy--done {
  opacity: 1;
}

.chat-mermaid-copy:hover {
  color: var(--semantic-text, #c5c9c5);
  border-color: var(--color-violet, #8992a7);
}

.chat-mermaid-copy--done {
  color: var(--semantic-success, #87a987);
  border-color: var(--semantic-success, #87a987);
}

.chat-mermaid-viewer-svg :deep(svg) {
  display: block;
  height: auto;
}

@media (prefers-reduced-motion: reduce) {
  .chat-mermaid-copy {
    transition: none;
  }
}
</style>
