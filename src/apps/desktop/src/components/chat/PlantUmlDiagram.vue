<script setup lang="ts">
/** PlantUmlDiagram — one `<plantuml>…</plantuml>` block of an assistant turn. The SVG comes from a
 * PlantUML server (see `helpers/plantuml.ts`); there is no local renderer to fail, only a request
 * that can fail, so a refusal shows the source rather than an empty frame. */
import { computed, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import DiagramViewer from './DiagramViewer.vue'
import { inlineDiagramLayout } from '../../helpers/diagramViewport'
import type { DiagramSize } from '../../helpers/diagramViewport'
import { plantumlSvgUrl, resolvePlantumlServer } from '../../helpers/plantuml'

const props = defineProps<{ source: string }>()

const copied = ref(false)
const preview = ref(false)
const frame = ref<HTMLElement | null>(null)
const available = ref(0)
const natural = ref<DiagramSize | null>(null)
let copyTimer: ReturnType<typeof setTimeout> | null = null

/** Both outcomes are keyed on the source they belong to, so new source is a new request without a
 * watcher — a stale `failed` from the previous block can never hide the next one's image. */
const failedFor = ref<string | null>(null)
const loadedFor = ref<string | null>(null)
const failed = computed(() => failedFor.value === props.source)
const loaded = computed(() => loadedFor.value === props.source)

const url = computed(() => plantumlSvgUrl(props.source))
/** The host only, for the failure note — the encoded source is unreadable and would only scroll. */
const serverHost = computed(() => {
  const server = resolvePlantumlServer()
  const withoutScheme = server.replace(/^https?:\/\//, '')
  return withoutScheme.split('/')[0] ?? server
})

/** The column the drawing has to live in; `available` only re-renders on a real change. */
const measure = (): void => {
  available.value = frame.value?.clientWidth ?? 0
}

onMounted(measure)
onUpdated(measure)

const layout = computed(() =>
  failed.value ? null : inlineDiagramLayout(natural.value, available.value),
)
const zoomStyle = computed(() =>
  layout.value ? { width: `${layout.value.width}px`, maxWidth: 'none' } : undefined,
)

const onImageLoad = (event: Event): void => {
  loadedFor.value = props.source
  const image = event.target
  if (!(image instanceof HTMLImageElement)) return
  if (image.naturalWidth > 0 && image.naturalHeight > 0) {
    natural.value = { width: image.naturalWidth, height: image.naturalHeight }
  }
}

const onImageError = (): void => {
  failedFor.value = props.source
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

</script>

<template>
  <figure ref="frame" class="chat-plantuml" data-testid="chat-plantuml">
    <div v-if="!failed" class="chat-plantuml-canvas">
      <button
        type="button"
        class="chat-plantuml-zoom"
        title="Click to enlarge"
        aria-label="Enlarge diagram"
        data-testid="chat-plantuml-zoom"
        @click="preview = true"
      >
        <img
          class="chat-plantuml-img"
          :class="{ 'chat-plantuml-img--ready': loaded }"
          :style="zoomStyle"
          :src="url"
          alt="PlantUML diagram"
          data-testid="chat-plantuml-img"
          @load="onImageLoad"
          @error="onImageError"
        />
      </button>
      <button
        type="button"
        class="chat-plantuml-copy"
        :class="{ 'chat-plantuml-copy--done': copied }"
        :title="copied ? 'Copied' : 'Copy PlantUML source'"
        :aria-label="copied ? 'Copied' : 'Copy PlantUML source'"
        data-testid="chat-plantuml-copy"
        @click="copySource"
      >
        <UiIcon name="clipboard" size-class="w-3.5 h-3.5" />
      </button>
    </div>
    <template v-else>
      <figcaption class="chat-plantuml-note" data-testid="chat-plantuml-error">
        Diagram not rendered — the PlantUML server ({{ serverHost }}) did not answer.
      </figcaption>
      <pre class="chat-plantuml-source"><code>{{ source }}</code></pre>
    </template>

    <figcaption v-if="layout?.overflow" class="chat-plantuml-wide" data-testid="chat-plantuml-wide">
      Wider than this column — scroll across, or open it to zoom.
    </figcaption>

    <DiagramViewer
      :open="preview"
      label="PlantUML diagram"
      :natural="natural"
      :original="failed ? undefined : url"
      @close="preview = false"
    >
      <img class="chat-plantuml-viewer-img" :src="url" alt="PlantUML diagram" />
    </DiagramViewer>
  </figure>
</template>

<style scoped>
.chat-plantuml {
  position: relative;
  display: block;
  margin: 0;
  /* Same frame chrome as `.chat-mermaid` and ChatView's `.chat-html-frame`: an html block, a mermaid
     diagram and a PlantUML diagram read as one family. */
  padding: 12px;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
}

/* A drawing wider than the column keeps its legible width and scrolls here, with a visible thin
   scrollbar so the overflow is discoverable. */
.chat-plantuml-canvas {
  max-height: 70vh;
  overflow: auto;
  scrollbar-color: var(--color-gray-3, #7a8382) transparent;
  scrollbar-width: thin;
}

.chat-plantuml-canvas::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}

.chat-plantuml-canvas::-webkit-scrollbar-thumb {
  border-radius: 4px;
  background: var(--color-gray-3, #7a8382);
}

/* The SVG arrives with its own canvas from `skinparam backgroundColor`; the frame stays the frame. */
.chat-plantuml-zoom {
  display: block;
  min-width: 100%;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  text-align: center;
  cursor: zoom-in;
}

.chat-plantuml-zoom:focus-visible {
  outline: 1px solid var(--semantic-link, #8ba4b0);
  outline-offset: 4px;
  border-radius: 4px;
}

/* Nothing is reserved until the server answers, so a slow render does not leave a broken-image icon
   the size of the transcript: the box only takes height once the SVG is in. */
.chat-plantuml-img {
  display: none;
  margin: 0 auto;
  max-width: 100%;
  height: auto;
}

.chat-plantuml-img--ready {
  display: block;
}

.chat-plantuml-wide {
  margin-top: 8px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
}

.chat-plantuml-copy {
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

.chat-plantuml:hover .chat-plantuml-copy,
.chat-plantuml-copy:focus-visible,
.chat-plantuml-copy--done {
  opacity: 1;
}

.chat-plantuml-copy:hover {
  color: var(--semantic-text, #c5c9c5);
  border-color: var(--color-violet, #8992a7);
}

.chat-plantuml-copy--done {
  color: var(--semantic-success, #87a987);
  border-color: var(--semantic-success, #87a987);
}

.chat-plantuml-note {
  margin-bottom: 8px;
  color: var(--semantic-text-muted, #a6a69c);
  font-size: var(--text-dense);
}

.chat-plantuml-source {
  margin: 0;
  padding: 8px 10px;
  overflow-x: auto;
  border-radius: 4px;
  background: var(--color-bg-p1, #282727);
  color: var(--semantic-text, #c5c9c5);
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: var(--text-dense);
}

.chat-plantuml-viewer-img {
  display: block;
  height: auto;
}

@media (prefers-reduced-motion: reduce) {
  .chat-plantuml-copy {
    transition: none;
  }
}
</style>
