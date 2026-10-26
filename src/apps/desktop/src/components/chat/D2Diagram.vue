<script setup lang="ts">
/** D2Diagram — one `<d2>…</d2>` block of an assistant turn. The SVG comes from a D2 server (see
 * `helpers/d2.ts`); the URL is async because the source is deflated first, so the draw is keyed on
 * the source the way MermaidDiagram does it and never on a watcher. */
import { onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { d2SvgUrl, resolveD2Server } from '../../helpers/d2'

const props = defineProps<{ source: string }>()

const url = ref('')
const note = ref('')
const loaded = ref(false)
const copied = ref(false)
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

onMounted(draw)
onUpdated(draw)

const onImageError = (): void => {
  note.value = `the D2 server (${serverHost()}) did not render it`
  loaded.value = false
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
  <figure class="chat-d2" data-testid="chat-d2">
    <div v-if="url && !note" class="chat-d2-canvas">
      <a
        class="chat-d2-zoom"
        :href="url"
        target="_blank"
        rel="noopener noreferrer"
        title="Open the diagram"
        data-testid="chat-d2-open"
      >
        <img
          class="chat-d2-img"
          :class="{ 'chat-d2-img--ready': loaded }"
          :src="url"
          alt="D2 diagram"
          data-testid="chat-d2-img"
          @load="loaded = true"
          @error="onImageError"
        />
      </a>
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
  overflow-x: auto;
  scrollbar-width: none;
}

.chat-d2::-webkit-scrollbar {
  display: none;
}

.chat-d2-zoom {
  display: block;
  width: 100%;
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
  font-size: 0.8125rem;
}

.chat-d2-source {
  margin: 0;
  padding: 8px 10px;
  overflow-x: auto;
  border-radius: 4px;
  background: var(--color-bg-p1, #282727);
  color: var(--semantic-text, #c5c9c5);
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 0.8125rem;
}

@media (prefers-reduced-motion: reduce) {
  .chat-d2-copy {
    transition: none;
  }
}
</style>
