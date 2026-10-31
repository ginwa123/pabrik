<script setup lang="ts">
/** D2Diagram — one `<d2>…</d2>` block of an assistant turn. The SVG comes from a D2 server (see
 * `helpers/d2.ts`); the URL is async because the source is deflated first, so the draw is keyed on
 * the source the way MermaidDiagram does it and never on a watcher. */
import { computed, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import DiagramViewer from './DiagramViewer.vue'
import { d2SvgUrl, resolveD2Server } from '../../helpers/d2'
import { inlineDiagramLayout } from '../../helpers/diagramViewport'
import type { DiagramSize } from '../../helpers/diagramViewport'

const props = defineProps<{ source: string }>()

const url = ref('')
const note = ref('')
const loaded = ref(false)
const copied = ref(false)
const preview = ref(false)
const frame = ref<HTMLElement | null>(null)
const available = ref(0)
const natural = ref<DiagramSize | null>(null)
let copyTimer: ReturnType<typeof setTimeout> | null = null
/** The source this component has already asked for — `onUpdated` fires on ANY parent re-render. */
let drawn = ''
/** A slow encode must not overwrite the result of a newer one. */
let token = 0

const serverHost = (): string => {
  const server = resolveD2Server().replace(/^https?:\/\//, '')
  return server.split('/')[0] ?? server
}

const draw = (): void => {
  if (drawn === props.source) return
  drawn = props.source
  const mine = ++token
  url.value = ''
  note.value = ''
  loaded.value = false
  natural.value = null
  d2SvgUrl(props.source).then(
    (next) => {
      if (mine === token) url.value = next
    },
    () => {
      // No `CompressionStream` in this browser — nothing can be sent, so say that rather than
      // blaming the server.
      if (mine === token) note.value = 'this browser cannot encode the D2 source'
    },
  )
}

/** The column the drawing has to live in; `available` only re-renders on a real change. */
const measure = (): void => {
  available.value = frame.value?.clientWidth ?? 0
}

onMounted(() => {
  draw()
  measure()
})
onUpdated(() => {
  draw()
  measure()
})

const layout = computed(() => inlineDiagramLayout(natural.value, available.value))
const zoomStyle = computed(() =>
  layout.value ? { width: `${layout.value.width}px`, maxWidth: 'none' } : undefined,
)

const onImageLoad = (event: Event): void => {
  loaded.value = true
  const image = event.target
  if (!(image instanceof HTMLImageElement)) return
  if (image.naturalWidth > 0 && image.naturalHeight > 0) {
    natural.value = { width: image.naturalWidth, height: image.naturalHeight }
  }
}

const onImageError = (): void => {
  note.value = `the D2 server (${serverHost()}) did not render it`
  loaded.value = false
  natural.value = null
}

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
      // No clipboard permission: stay in the idle state rather than claim success.
      copied.value = false
    })
}

onBeforeUnmount(() => {
  if (copyTimer) clearTimeout(copyTimer)
})
</script>

<template>
  <figure ref="frame" class="chat-d2" data-testid="chat-d2">
    <div v-if="url && !note" class="chat-d2-canvas">
      <button
        type="button"
        class="chat-d2-zoom"
        title="Click to enlarge"
        aria-label="Enlarge diagram"
        data-testid="chat-d2-zoom"
        @click="preview = true"
      >
        <img
          class="chat-d2-img"
          :class="{ 'chat-d2-img--ready': loaded }"
          :style="zoomStyle"
          :src="url"
          alt="D2 diagram"
          data-testid="chat-d2-img"
          @load="onImageLoad"
          @error="onImageError"
        />
      </button>
      <button
        type="button"
        class="chat-d2-copy"
        :class="{ 'chat-d2-copy--done': copied }"
        :title="copied ? 'Copied' : 'Copy D2 source'"
        :aria-label="copied ? 'Copied' : 'Copy D2 source'"
        data-testid="chat-d2-copy"
        @click="copySource"
      >
        <UiIcon name="clipboard" size-class="w-3.5 h-3.5" />
      </button>
    </div>
    <template v-else>
      <figcaption v-if="note" class="chat-d2-note" data-testid="chat-d2-error">
        Diagram not rendered — {{ note }}.
      </figcaption>
      <pre class="chat-d2-source"><code>{{ source }}</code></pre>
    </template>

    <figcaption v-if="layout?.overflow" class="chat-d2-wide" data-testid="chat-d2-wide">
      Wider than this column — scroll across, or open it to zoom.
    </figcaption>

    <DiagramViewer
      :open="preview"
      label="D2 diagram"
      :natural="natural"
      :original="url || undefined"
      @close="preview = false"
    >
      <img class="chat-d2-viewer-img" :src="url" alt="D2 diagram" />
    </DiagramViewer>
  </figure>
</template>

<style scoped>
.chat-d2 {
  position: relative;
  display: block;
  margin: 0;
  /* Same frame chrome as `.chat-mermaid`, `.chat-plantuml` and ChatView's `.chat-html-frame`. */
  padding: 12px;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
}

/* A drawing wider than the column keeps its legible width and scrolls here, with a visible thin
   scrollbar so the overflow is discoverable. */
.chat-d2-canvas {
  max-height: 70vh;
  overflow: auto;
  scrollbar-color: var(--color-gray-3, #7a8382) transparent;
  scrollbar-width: thin;
}

.chat-d2-canvas::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}

.chat-d2-canvas::-webkit-scrollbar-thumb {
  border-radius: 4px;
  background: var(--color-gray-3, #7a8382);
}

.chat-d2-zoom {
  display: block;
  min-width: 100%;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  text-align: center;
  cursor: zoom-in;
}

.chat-d2-zoom:focus-visible {
  outline: 1px solid var(--semantic-link, #8ba4b0);
  outline-offset: 4px;
  border-radius: 4px;
}

/* Nothing is reserved until the server answers, so a slow render does not leave a broken-image icon
   the height of the transcript. */
.chat-d2-img {
  display: none;
  margin: 0 auto;
  max-width: 100%;
  height: auto;
}

.chat-d2-img--ready {
  display: block;
}

.chat-d2-wide {
  margin-top: 8px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
}

.chat-d2-copy {
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

.chat-d2:hover .chat-d2-copy,
.chat-d2-copy:focus-visible,
.chat-d2-copy--done {
  opacity: 1;
}

.chat-d2-copy:hover {
  color: var(--semantic-text, #c5c9c5);
  border-color: var(--color-violet, #8992a7);
}

.chat-d2-copy--done {
  color: var(--semantic-success, #87a987);
  border-color: var(--semantic-success, #87a987);
}

.chat-d2-note {
  margin-bottom: 8px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
}

.chat-d2-source {
  margin: 0;
  padding: 8px 10px;
  overflow-x: auto;
  border-radius: 4px;
  background: var(--color-bg-p1, #282727);
  color: var(--semantic-text, #c5c9c5);
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: var(--text-dense);
}

.chat-d2-viewer-img {
  display: block;
  height: auto;
}

@media (prefers-reduced-motion: reduce) {
  .chat-d2-copy {
    transition: none;
  }
}
</style>
