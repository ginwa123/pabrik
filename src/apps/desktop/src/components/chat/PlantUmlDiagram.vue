<script setup lang="ts">
/** PlantUmlDiagram — one `<plantuml>…</plantuml>` block of an assistant turn. The SVG comes from a
 * PlantUML server (see `helpers/plantuml.ts`); there is no local renderer to fail, only a request
 * that can fail, so a refusal shows the source rather than an empty frame. */
import { computed, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { plantumlSvgUrl, resolvePlantumlServer } from '../../helpers/plantuml'

const props = defineProps<{ source: string }>()

const copied = ref(false)
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
  <figure class="chat-plantuml" data-testid="chat-plantuml">
    <div v-if="!failed" class="chat-plantuml-canvas">
      <a
        class="chat-plantuml-zoom"
        :href="url"
        target="_blank"
        rel="noopener noreferrer"
        title="Open the diagram"
        data-testid="chat-plantuml-open"
      >
        <img
          class="chat-plantuml-img"
          :class="{ 'chat-plantuml-img--ready': loaded }"
          :src="url"
          alt="PlantUML diagram"
          data-testid="chat-plantuml-img"
          @load="loadedFor = props.source"
          @error="failedFor = props.source"
        />
      </a>
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
  overflow-x: auto;
  scrollbar-width: none;
}

.chat-plantuml::-webkit-scrollbar {
  display: none;
}

/* The SVG arrives with its own canvas from `skinparam backgroundColor`; the frame stays the frame. */
.chat-plantuml-zoom {
  display: block;
  width: 100%;
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
  font-size: 0.8125rem;
}

.chat-plantuml-source {
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
  .chat-plantuml-copy {
    transition: none;
  }
}
</style>
