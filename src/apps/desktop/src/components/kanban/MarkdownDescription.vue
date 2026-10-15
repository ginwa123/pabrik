<!--
  MarkdownDescription — display-only renderer for a Markdown string.

  Used to show a kanban task description in two places:
    1. The Task details dialog (when not in edit mode).
    2. The KanbanCard preview on the column (with `maxHeight` to clip).

  What it does:
    - Calls `marked.parse(source, { async: false })` to get HTML.
    - Post-processes the HTML to wrap `@/path/to/file` tokens in a
      clickable `.md-file-chip` span. The user types these tokens
      directly into the description via the `KanbanDescriptionEditor`
      `@`-trigger file picker; this is how we surface them visually.
    - Renders the HTML via `v-html` inside `<div class="markdown-content">`.

  Trust model (XSS):
    The `source` is user-authored task data. `marked.parse` is the same
    library ChatView uses (line 183) — and the same self-XSS trust model
    applies: a user can only inject markup into their own task. No CSP
    change is required. Image data URLs are passed through verbatim by
    marked, which is exactly what we want for the inline-image case.

  @path chip detection:
    - Regex: `/@(\/[^\s)\]}>,"'`]+)/g` — leading `@`, then `/`, then any
      chars except whitespace, closing brackets, quotes, backticks.
    - Two non-matches: `@username` (no leading slash) and `/path/with/no/at`.
    - The path is escaped via a small replace; the surrounding markdown
      continues to be rendered normally (the chip is a `<span>` that sits
      inside whatever block the markdown produced).
-->
<script setup lang="ts">
import { computed } from 'vue'
import { marked } from 'marked'

const props = withDefaults(
  defineProps<{
    source: string | null | undefined
    cwd?: string
    maxHeight?: string
    testId?: string
  }>(),
  {
    cwd: '',
    maxHeight: '',
    testId: 'markdown-description',
  },
)

// Matches `/path/to/file` (group 1) with an optional leading `@`.
// The `@` is supported for backward compatibility with descriptions
// authored before the rich editor change — both `@/path` and `/path`
// render as chips. The stored chip path INCLUDES the leading `/` (the
// leading `@` is stripped) so consumers don't need to special-case.
//
// Character class restrictions keep false positives low:
//   - Must start with `/` (matches file paths, not URLs with schemes)
// - Allows word chars, dots, slashes, hyphens - Excludes whitespace, closing brackets, quotes,
// backticks - Excludes `<` to prevent capturing across HTML tag boundaries To opt out of chip
// rendering for a specific `/path`, wrap it in backticks — the inline-code styling takes over.
const FILE_PATH_REGEX = /@?(\/[^\s)\]}>,"'<`]+)/g

// The chip is built as an HTML string and injected with v-html, so a Vue component cannot draw its
// leading mark. These are the `file` subpaths from `components/ui/icons.ts`, inlined once so the
// chip and `<UiIcon name="file">` render the same shape.

// Both subpaths share one `<path>` — a multi-subpath `d` draws identically to two sibling paths.
const FILE_CHIP_MARK =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="vertical-align:-2px"><path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2zM14 2v5a1 1 0 0 0 1 1h5"/></svg>'

// Private-use Unicode char used as a sentinel in the source before it is fed to marked. Marked
// treats unknown chars as plain text and passes them through verbatim, so the placeholder survives
// the round-trip and we can substitute the chip span in afterwards.

// Using `\uE000` (private use area) means there's essentially zero chance a user types this exact
// sequence naturally.
const PLACEHOLDER_PREFIX = '\uE000_FILECHIP_'
const PLACEHOLDER_SUFFIX = '_\uE000'

const emit = defineEmits<{
  /**    * Fires when the user clicks a file-path chip. The path is resolved against the consumer's `cwd`
   * prop (e.g. the kanban's `item.path`) — the chip itself stores the path verbatim, the consumer
   * decides what to do with it. */
  'file-click': [path: string]
}>()

// Render the source through marked, then splice `/path` tokens into
// clickable chip spans.
//
// Three-phase approach (placeholder substitution):
//   1. Protect data: URLs from the file-path regex. A `data:image/...`
//      URL contains `/png` (the MIME extension) which would
//      otherwise match FILE_PATH_REGEX and corrupt the img src.
//   2. Replace each `/path` (or `@/path`) with
//      `\uE000_FILECHIP_<i>_\uE000` and stash the path in an array.
//      Marked never sees the path so it can't try to autolink or
//      wrap it in `<a>`.
//   3. Run marked.parse() on the placeholder-bearing source.
//   4. Post-process: substitute each placeholder with a chip span,
//      then restore the data: URLs.
const renderedHtml = computed<string>(() => {
  if (!props.source) return ''

  // Phase 1 — protect data: URLs from the file-path regex. We stash
  // the original URL bytes and put a placeholder that the regex
  // can't match (the .sqlite-style dot prefix).
  const dataUrls: string[] = []
  let working = props.source.replace(/data:[^\s)]+/g, (match) => {
    const idx = dataUrls.length
    dataUrls.push(match)
    return `_DATA_URL_${idx}_END_`
  })

  // Phase 2 — collect chips and substitute placeholders.
  const chips: string[] = []
  working = working.replace(
    FILE_PATH_REGEX,
    (_match, pathWithSlash, offset, fullString) => {
      // Skip matches inside backticks (inline code) — the user has
      // explicitly opted out of chip rendering by wrapping in code.
      const prefix = fullString.slice(0, offset)
      const backticks = (prefix.match(/`/g) ?? []).length
      if (backticks % 2 === 1) return _match
      // Skip matches inside our data: URL placeholders (the regex
      // couldn't match any of those because we replaced them with
      // non-path-like text, but be defensive).
      if (pathWithSlash.length < 2) return _match
      const idx = chips.length
      chips.push(pathWithSlash)
      return `${PLACEHOLDER_PREFIX}${idx}${PLACEHOLDER_SUFFIX}`
    },
  )

  // Phase 3 — marked.parse on the safe input.
  let html: string
  try {
    html = marked.parse(working, { async: false }) as string
  } catch {
    const escaped = props.source
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
    return `<pre>${escaped}</pre>`
  }

  // Phase 4 — substitute placeholders with chip spans, then restore
  // the data: URLs.
  for (let i = 0; i < chips.length; i++) {
    const placeholder = `${PLACEHOLDER_PREFIX}${i}${PLACEHOLDER_SUFFIX}`
    const path = chips[i] ?? ''
    const chip = `<span class="md-file-chip" data-file-path="${path}">${FILE_CHIP_MARK} ${path}</span>`
    html = html.split(placeholder).join(chip)
  }
  for (let i = 0; i < dataUrls.length; i++) {
    html = html.split(`_DATA_URL_${i}_END_`).join(dataUrls[i] ?? '')
  }

  return html
})

// Event-delegated click handler: catches clicks on `.md-file-chip`
// spans (v-html content can't bind listeners per-element). Emits
// `file-click` with the chip's data-file-path attribute.
const onChipClick = (event: MouseEvent) => {
  const target = event.target as HTMLElement | null
  if (!target) return
  const chip = target.closest('.md-file-chip') as HTMLElement | null
  if (!chip) return
  const path = chip.dataset.filePath
  if (path) emit('file-click', path)
}

const hostStyle = computed<string>(() => {
  if (!props.maxHeight) return ''
  return `max-height: ${props.maxHeight}; overflow: hidden;`
})
</script>

<template>
  <div
    class="markdown-content"
    :data-testid="testId"
    :style="hostStyle || undefined"
    v-html="renderedHtml"
    @click="onChipClick"
  />
</template>

<style scoped>
/* Chip styling — visual marker for `@/path` references inside markdown.
   Keeps the chip readable on both light and dark backgrounds; the
   `--semantic-text-dim` muted text color echoes the inline-code chip
   already present in the .markdown-content stylesheet. */
.md-file-chip {
  display: inline-block;
  padding: 1px 6px;
  margin: 0 1px;
  border-radius: 4px;
  font-family: var(--font-mono);
  font-size: 0.85em;
  background-color: var(--color-bg-p1);
  color: var(--semantic-text);
  border: 1px solid var(--color-border);
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.md-file-chip:hover {
  background-color: var(--color-violet);
  color: var(--color-bg);
  border-color: var(--color-violet);
}
</style>