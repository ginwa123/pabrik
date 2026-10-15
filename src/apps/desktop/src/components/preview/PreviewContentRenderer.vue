<!--
  PreviewContentRenderer — shared renderer for rich text content
  (markdown / text / code / image / html).

  Renders fetched or inline text content inside the chat bubble (used by
  PresentFiles for per-file text previews). Supports 5 content types
  (markdown / text / code / image / html) without copy-paste drift.

  HTML previews render in a sandboxed iframe that auto-sizes to fit
  content height, plus an "Open in new tab" button
  (data-testid="preview-open-new-tab-button") that opens the HTML
  in a new browser tab via a Blob URL — letting the user see the
  full-width page when the inline view truncates.

  Props:
    - `contentType`: one of 'markdown' | 'text' | 'code' | 'image' | 'html'.
    - `args`: object with `content`, `title`, `caption`, `language` fields.
      `content` is the raw payload. `title` renders above. `caption`
      renders below. `language` selects the code fence hint (matches the
      `present_files` text-preview convention).
    - `variant` (default 'inline'): kept for backward compat, only
      `'inline'` layout is used (compact chat-bubble layout).

  Branch table:

    | content_type  | Render path                                |
    |---------------|---------------------------------------------|
    | markdown      | marked.parse(c) → v-html                    |
    | text          | <pre class="whitespace-pre-wrap"> + escaped |
    | code          | <pre><code class="language-X"> + escaped    |
    | image         | <img :src="data:/http URL only">            |
    | html          | <iframe sandbox="allow-scripts" srcdoc=...> +  |
    |               | (inline only) "Open full preview" → button  |
    | (anything else) | empty container (defensive)              |

  Security note for the `html` branch:
    - iframe gets a NULL origin (no allow-same-origin), so its JS
      cannot read the parent app's cookies, localStorage, or window.
    - no allow-forms (forms render but cannot submit).
    - no allow-top-navigation (window.open blocked).
    This matches the existing DesignElementPreview.vue pattern.

-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { marked } from 'marked'
import {
  PREVIEW_AUTO_RESIZE_SCRIPT,
  PREVIEW_AUTO_RESIZE_SOURCE,
  FRAME_NO_SCROLLBAR_STYLE,
  growFrameToContent,
  readAutoResizeHeight,
} from '@/helpers'

export interface PreviewArgs {
  content?: string
  title?: string
  language?: string
  caption?: string
}

const props = withDefaults(
  defineProps<{
    contentType: 'markdown' | 'text' | 'code' | 'image' | 'html'
    args: PreviewArgs
    /**      * Layout variant (kept for backward compat). Only `'inline'` is used — compact chat-bubble
     * layout that auto-resizes to fit the iframe's content height, plus an "Open in new tab" button
     * for HTML content. */
    variant?: 'side' | 'inline'
  }>(),
  { variant: 'inline' },
)

// ─── Iframe ref + auto-resize message handling ──────────────────────
const iframeRef = ref<HTMLIFrameElement | null>(null)
const MIN_IFRAME_HEIGHT = 200

function onIframeMessage(e: MessageEvent) {
  // Filter by source — only messages from our own auto-resize script.
  // Grows to the FULL content height (no upper cap) so no inner
  // scrollbar ever appears — the outer chat scroller owns scrolling.
  const reported = readAutoResizeHeight(e, PREVIEW_AUTO_RESIZE_SOURCE)
  if (reported === null) return
  const iframe = iframeRef.value
  if (!iframe) return
  iframe.style.height = `${growFrameToContent(reported, MIN_IFRAME_HEIGHT)}px`
}

onMounted(() => {
  if (typeof window !== 'undefined') {
    window.addEventListener('message', onIframeMessage)
  }
})

onUnmounted(() => {
  if (typeof window !== 'undefined') {
    window.removeEventListener('message', onIframeMessage)
  }
})

// ─── Auto-resize script (prepended to the iframe srcdoc) ──────────── The reporter script and its
// postMessage parser live in helpers/iframeAutoResize.ts — shared with ChatView.vue's `<html>`
// frames.
// Same security contract as before: the sandboxed (NULL-origin) frame only reports its own
// scrollHeight/scrollWidth; the parent only writes a clamped iframe.style.height.
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

// markdown / text / code branch (consumed via v-html). The other
// branches (`image`, `html`) render via dedicated elements below
// — the v-html string is empty for them so we don't double-render.
const renderedContent = computed<string>(() => {
  const ct = props.contentType
  const c = props.args.content ?? ''
  if (ct === 'markdown') {
    try {
      return marked.parse(c, { async: false }) as string
    } catch {
      return `<pre>${escapeHtml(c)}</pre>`
    }
  }
  if (ct === 'text') {
    return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
  }
  if (ct === 'code') {
    const lang = props.args.language ?? 'plaintext'
    return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
  }
  // 'image' and 'html' render via dedicated template branches.
  return ''
})

// XSS guard for image: only data: URLs and http(s) URLs are allowed.
// Other payloads (e.g. javascript:) silently render nothing — the
// underlying `imageSrc` computed returns null in that case.
const imageSrc = computed<string | null>(() => {
  if (props.contentType !== 'image') return null
  const c = props.args.content ?? ''
  if (c.startsWith('data:') || c.startsWith('http://') || c.startsWith('https://')) {
    return c
  }
  return null
})

/**
 * Build the iframe's `srcdoc` value from the user HTML.
 *
 * CRITICAL: do NOT manually escape `<`, `>`, `&`, `"` here. The browser's
 * `setAttribute('srcdoc', value)` path automatically encodes those four
 * characters for the attribute value, then the iframe's own parser
 * decodes them back when loading the document. Manually escaping here
 * produces DOUBLE-escaped HTML.
 *
 * Vue's reactive `:srcdoc` binding calls setAttribute for us.
 *
 * Also wraps the HTML in:
 *   1. A tiny `<style>` reset so the preview doesn't get a default-
 *      margin surprise from the browser body.
 *   2. The AUTO_RESIZE_SCRIPT (prepended BEFORE the user's HTML) which
 *      sets up the postMessage protocol that makes the iframe auto-size
 *      to fit its content height. Follows the sandboxed-iframe pattern.
 */
const htmlSrcDoc = computed<string | null>(() => {
  if (props.contentType !== 'html') return null
  const raw = props.args.content ?? ''
  return `${PREVIEW_AUTO_RESIZE_SCRIPT}<style>html,body{margin:0;padding:0;background:#fff;}${FRAME_NO_SCROLLBAR_STYLE}</style>${raw}`
})

// ─── Open in new tab ─────────────────────────────────────────────── HTML previews offer an "Open
// in new tab" action that builds a Blob URL from the raw HTML and opens it via window.open. The
// iframe stays sandboxed (NULL origin); the new tab gets the full viewport width for wide content.
function openInNewTab() {
  if (typeof window === 'undefined' || typeof URL === 'undefined') return
  try {
    const raw = props.args.content ?? ''
    const blob = new Blob([raw], { type: 'text/html' })
    const url = URL.createObjectURL(blob)
    window.open(url, '_blank', 'noopener')
    // Revoke after a delay so the new tab has time to load.
    window.setTimeout(() => {
      try {
        URL.revokeObjectURL(url)
      } catch {
        /* ignore */
      }
    }, 60_000)
  } catch {
    /* ignore — popup blocked or blob unsupported */
  }
}
</script>

<template>
  <div class="preview-content-renderer">
    <div
      v-if="args.title"
      class="text-body font-semibold text-[var(--semantic-text)] mb-2 pb-2 border-b border-dashed border-[var(--color-border)]"
    >
      {{ args.title }}
      <span
        v-if="args.language && contentType === 'code'"
        class="ml-2 text-dense text-[var(--semantic-text-muted)] font-normal"
        >[{{ args.language }}]</span
      >
    </div>

    <div v-if="contentType === 'image'" class="flex justify-center bg-black/[0.04] p-2 rounded">
      <img
        v-if="imageSrc"
        :src="imageSrc"
        :alt="args.title || args.caption || 'Preview image'"
        class="max-w-full max-h-96 object-contain"
        @error="
          (e) => {
            ;(e.target as HTMLImageElement).style.display = 'none'
          }
        "
      />
      <div v-else class="text-dense text-red-500 italic">
        Image source invalid (expected data: URL or http(s) URL)
      </div>
    </div>

    <!--
      HTML iframe container — auto-sized via the postMessage protocol
      in AUTO_RESIZE_SCRIPT (see <script setup>). The script reports
      the iframe's content height to the parent, which grows the frame
      to its FULL content height (no upper cap, no inner scrollbar —
      the outer chat scroller owns scrolling).
      The action row below the iframe offers "Open in new tab" for
      full-width viewing.
    -->
    <div
      v-else-if="contentType === 'html' && htmlSrcDoc"
      data-testid="preview-html-container"
      class="max-w-full rounded overflow-hidden border border-[var(--color-border)] bg-white"
    >
      <iframe
        ref="iframeRef"
        sandbox="allow-scripts"
        scrolling="no"
        :srcdoc="htmlSrcDoc"
        style="min-height: 200px; overflow: hidden; scrollbar-width: none"
        class="preview-html-iframe w-full border-0 block"
        :title="args.title || 'HTML preview'"
        data-testid="preview-html-iframe"
      />
      <div
        class="flex items-center justify-end gap-2 px-2 py-1.5 border-t border-[var(--color-border)] bg-black/[0.02]"
      >
        <button
          type="button"
          class="px-2 py-0.5 rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)] text-[var(--semantic-text)] text-dense cursor-pointer transition-colors"
          data-testid="preview-open-new-tab-button"
          title="Open HTML preview in a new browser tab"
          @click.stop="openInNewTab"
        >
          ↗ Open in new tab
        </button>
      </div>
    </div>

    <!--
      Markdown / text / code / image content (non-html) flow through
      the v-else branch below.
    -->
    <div
      v-else
      class="text-dense text-[var(--semantic-text)] markdown-content"
      v-html="renderedContent"
    />

    <div
      v-if="args.caption"
      class="mt-2 pt-2 text-dense italic text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]"
    >
      {{ args.caption }}
    </div>
  </div>
</template>

<style scoped>
.preview-html-iframe {
  overflow: hidden;
  scrollbar-width: none;
}

.preview-html-iframe::-webkit-scrollbar {
  display: none;
}

.markdown-content :deep(pre) {
  background: var(--color-code-bg, rgba(0, 0, 0, 0.05));
  padding: 0.5rem;
  border-radius: 0.25rem;
  overflow-x: auto;
}
/* Type is NOT restated here. style.css already sets `.markdown-content`
   h1-h4 and code off the scale, and a scoped :deep() rule outranks it —
   so declaring a size here makes the SAME markdown render at one size in a
   preview card and another in the transcript, which is the drift this
   scale exists to stop. Proved in a browser: with the sizes restated
   here the two hosts resolved to 20/18/16/12 against 24/20/18/14.
   Margins and weights stay: the card is deliberately tighter than the
   transcript, and that is a real difference worth keeping. */
.markdown-content :deep(code) {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
.markdown-content :deep(h1) {
  font-weight: 700;
  margin: 0.5rem 0;
}
.markdown-content :deep(h2) {
  font-weight: 600;
  margin: 0.4rem 0;
}
.markdown-content :deep(h3) {
  font-weight: 600;
  margin: 0.3rem 0;
}
.markdown-content :deep(p) {
  margin: 0.25rem 0;
  line-height: 1.4;
}
.markdown-content :deep(ul),
.markdown-content :deep(ol) {
  margin: 0.25rem 0 0.25rem 1.5rem;
}
.markdown-content :deep(a) {
  color: var(--color-violet);
  text-decoration: underline;
}
.markdown-content :deep(table) {
  border-collapse: collapse;
  margin: 0.5rem 0;
}
.markdown-content :deep(th),
.markdown-content :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.25rem 0.5rem;
}
</style>
