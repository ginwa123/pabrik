<script setup lang="ts">
/** MermaidDiagram — one `<mermaid>…</mermaid>` block of an assistant turn, drawn as SVG. Owns no
 * theme and no colour: `helpers/mermaid.ts` reads the app's CSS variables and initializes Mermaid
 * with them. A diagram that does not parse falls back to its own source rather than an empty box. */
import { computed, onMounted, onUpdated, ref } from 'vue'
import { renderMermaid } from '../../helpers/mermaid'

const props = defineProps<{ source: string }>()

const svg = ref('')
const failure = ref('')

// The source this component has already asked for. `onUpdated` fires on ANY parent re-render (a
// streaming sibling, a scroll), so the draw is keyed on the source rather than on the update.
let drawn = ''
// Token so a slow render cannot overwrite the result of a newer one.
let token = 0

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
</script>

<template>
  <figure class="chat-mermaid" data-testid="chat-mermaid">
    <!-- eslint-disable-next-line vue/no-v-html -->
    <div v-if="svg" class="chat-mermaid-canvas" data-testid="chat-mermaid-svg" v-html="svg"></div>
    <template v-else>
      <figcaption v-if="failureLine" class="chat-mermaid-note" data-testid="chat-mermaid-error">
        Diagram not rendered — {{ failureLine }}
      </figcaption>
      <pre class="chat-mermaid-source"><code>{{ source }}</code></pre>
    </template>
  </figure>
</template>

<style scoped>
.chat-mermaid {
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

/* Mermaid emits its own inline `max-width` on the svg; centring is the host's job. */
.chat-mermaid-canvas :deep(svg) {
  display: block;
  margin: 0 auto;
  max-width: 100%;
  height: auto;
}

.chat-mermaid-note {
  margin: 0 0 8px;
  font-size: var(--text-dense);
  color: var(--semantic-text-muted, #a6a69c);
}

.chat-mermaid-source {
  margin: 0;
  padding: 0;
  background: transparent;
  font-family: var(--font-mono);
  font-size: var(--text-dense);
  line-height: 1.5;
  color: var(--semantic-text-muted, #a6a69c);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
</style>
