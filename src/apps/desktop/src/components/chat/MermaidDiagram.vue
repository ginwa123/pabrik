<script setup lang="ts">
/** MermaidDiagram — one `<mermaid>…</mermaid>` block of an assistant turn, drawn as SVG. Owns no
 * theme and no colour: `helpers/mermaid.ts` reads the app's CSS variables and initializes Mermaid
 * with them. Clicking it opens a preview; the source is one click away. */
import { computed, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { renderMermaid } from '../../helpers/mermaid'

const props = defineProps<{ source: string }>()

const svg = ref('')
const failure = ref('')
const copied = ref(false)
const preview = ref(false)

// The source this component has already asked for. `onUpdated` fires on ANY parent re-render (a
// streaming sibling, a scroll), so the draw is keyed on the source rather than on the update.
let drawn = ''
// Token so a slow render cannot overwrite the result of a newer one.
let token = 0
let copyTimer: ReturnType<typeof setTimeout> | null = null
// Restored when the overlay closes: the transcript's own overflow is not always `''`.
let overflowBeforePreview = ''

const draw = (): void => {
  if (drawn === props.source) return
  drawn = props.source
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

onMounted(draw)
onUpdated(draw)

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

const onEscape = (event: KeyboardEvent): void => {
  if (event.key !== 'Escape') return
  event.stopPropagation()
  closePreview()
}

const openPreview = (): void => {
  preview.value = true
  if (typeof document === 'undefined') return
  overflowBeforePreview = document.body.style.overflow
  document.body.style.overflow = 'hidden'
  document.addEventListener('keydown', onEscape)
}

const closePreview = (): void => {
  preview.value = false
  if (typeof document === 'undefined') return
  document.body.style.overflow = overflowBeforePreview
  document.removeEventListener('keydown', onEscape)
}

onBeforeUnmount(() => {
  if (copyTimer) clearTimeout(copyTimer)
  if (preview.value) closePreview()
})
</script>

<template>
  <figure class="chat-mermaid" data-testid="chat-mermaid">
    <div v-if="svg" class="chat-mermaid-canvas">
      <button
        type="button"
        class="chat-mermaid-zoom"
        title="Click to enlarge"
        aria-label="Enlarge diagram"
        data-testid="chat-mermaid-enlarge"
        @click="openPreview"
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

    <Teleport to="body">
      <div
        v-if="preview"
        class="mermaid-preview"
        role="dialog"
        aria-modal="true"
        aria-label="Diagram preview"
        data-testid="mermaid-preview"
        @click="closePreview"
      >
        <figure class="mermaid-preview-body" @click.stop>
          <!-- eslint-disable-next-line vue/no-v-html -->
          <div class="mermaid-preview-svg" data-testid="mermaid-preview-svg" v-html="svg"></div>
        </figure>
        <button
          type="button"
          class="mermaid-preview-close"
          aria-label="Close diagram preview"
          data-testid="mermaid-preview-close"
          @click.stop="closePreview"
        >
          <svg
            class="w-6 h-6"
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
    </Teleport>
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
  overflow-x: auto;
  scrollbar-width: none;
}

.chat-mermaid::-webkit-scrollbar {
  display: none;
}

/* The whole drawing is the hit target: a real <button>, so Enter/Space work and the browser
   announces it, with the diagram's own pointer as the affordance. */
.chat-mermaid-zoom {
  display: block;
  width: 100%;
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

.mermaid-preview {
  position: fixed;
  inset: 0;
  z-index: 9999;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
  background-color: rgba(0, 0, 0, 0.85);
}

.mermaid-preview-body {
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 0;
  max-width: 90vw;
  max-height: 90vh;
  padding: 20px;
  overflow: auto;
  border: 1px solid var(--color-border, #282727);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
}

/* Mermaid writes `max-width: <own px>` inline; the preview's job is to beat it. The wrapper gets an
   explicit width so the svg's own `width: 100%` resolves against the lightbox, not its shrink-to-fit
   parent — without it the "enlarged" diagram came out barely wider than the inline one. */
.mermaid-preview-svg {
  width: min(70vw, 1100px);
}

.mermaid-preview-svg :deep(svg) {
  display: block;
  max-width: 100% !important;
  height: auto;
}

.mermaid-preview-close {
  position: absolute;
  top: 16px;
  right: 16px;
  padding: 8px;
  border: 0;
  background: none;
  color: white;
  cursor: pointer;
  opacity: 0.7;
  transition: opacity 0.2s;
}

.mermaid-preview-close:hover,
.mermaid-preview-close:focus-visible {
  opacity: 1;
}

@media (prefers-reduced-motion: reduce) {
  .chat-mermaid-copy,
  .mermaid-preview-close {
    transition: none;
  }
}
</style>
