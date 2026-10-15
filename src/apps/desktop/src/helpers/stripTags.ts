/** Strip thinking tags and extract content from special wrappers. This should be used at the
 * display layer (Vue), NOT in API responses. Memoized (2026-09-11). */

/** Why: ChatView calls this 2-3x per message on EVERY `messages` mutation — `filteredMessages`,
 * `hasBubbleContent` → `hasVisibleContent`, and (independently) `renderResponse` — and an SSE chunk
 * mutates `messages` once per chunk. */

/** So the same strings are re-scanned on every chunk, over the WHOLE loaded transcript, even though
 * only the streaming message changed. */

/** Measured on the real DB (newest-100 rows of a 2.21 MB session, 1.05 MB max row): 34 ms per
 * recompute — 79% of the total per-chunk render cost — which saturates the main thread (43 ms × 20
 * chunks/s) and is exactly the "webview freezes while a task streams" report. */

/** Cached hits are ~free, so the per-chunk cost drops to the parts that genuinely changed. The
 * value is returned by reference, so callers must treat it as read-only. */
const STRIP_CACHE_MAX_CHARS = 16 * 1024 * 1024
// A single entry larger than this is not cached: keeping it would evict
// everything else on arrival (cache thrash) for no benefit.
const STRIP_CACHE_MAX_ENTRY_CHARS = 4 * 1024 * 1024

const stripCache = new Map<string, string>()
let stripCacheChars = 0

/** Test-only cache reset (mirrors `_resetRenderResponseCache`). Not exported
 * through the helpers barrel so production callers can't clobber the cache. */
export const _resetStripThinkingTagsCache = (): void => {
  stripCache.clear()
  stripCacheChars = 0
}

/**  * Test-only cache introspection. `hits` is not tracked — the observable contract tests assert on
 * `entries` (a cache hit must not add an entry, so a repeated call leaves the count unchanged). */
export const _stripThinkingTagsCacheStats = (): { entries: number; chars: number } => ({
  entries: stripCache.size,
  chars: stripCacheChars,
})

export function stripThinkingTags(content: string | undefined): string {
  if (!content) return ''

  const cached = stripCache.get(content)
  if (cached !== undefined) return cached

  const result = computeStripThinkingTags(content)
  const entryChars = content.length + result.length
  if (entryChars <= STRIP_CACHE_MAX_ENTRY_CHARS) {
    if (stripCacheChars + entryChars > STRIP_CACHE_MAX_CHARS) {
      stripCache.clear()
      stripCacheChars = 0
    }
    stripCache.set(content, result)
    stripCacheChars += entryChars
  }
  return result
}

function computeStripThinkingTags(content: string): string {
  const str = String(content).trim()

  const hasThink = /<think>[\s\S]*?<\/think>/i.test(str)
  const hasPlain = /<plain>/i.test(str)
  const hasMarkdown = /<markdown>/i.test(str)
  const hasHtml = /<html>/i.test(str)

  // Only <think> exists, keep original content
  if (hasThink && !hasPlain && !hasMarkdown && !hasHtml) {
    return str
  }

  let result = str

  // Remove think block only when another content tag exists
  if (hasThink && (hasPlain || hasMarkdown || hasHtml)) {
    result = result.replace(/<think>[\s\S]*?<\/think>/gi, '')
  }

  // Unwrap plain tags
  result = result.replace(/<plain>\s*/gi, '').replace(/\s*<\/plain>/gi, '')

  // Unwrap markdown tags
  result = result.replace(/<markdown>\s*/gi, '').replace(/\s*<\/markdown>/gi, '')

  // Unwrap html tags (inner content is rendered as a live sandboxed
  // iframe block by ChatView — see getHtmlTags/isHtmlTags below).
  result = result.replace(/<html>\s*/gi, '').replace(/\s*<\/html>/gi, '')

  // 2026-08-24 (task_1787545088500_6, bug B) — the LLM sometimes wraps a <markdown> answer in a
  // ```html / ```markdown / ``` fence (real DB rows 1787542307914248765 + 1787545407823788849 from
  // session task_1787540075329_3).

  // The fence survives the unwrap above and `marked.parse` then renders the ENTIRE message as one
  // literal <pre> code block — users see raw `##`/`**`/ `[link](url)` as plain text instead of
  // formatted markdown.

  // Only strip fences anchored at the start/end of the string so we don't disturb mid-line triple
  // backticks or fenced code blocks inside the markdown body (which a user might have written).
  result = result.replace(/^```(?:html|markdown|md)?\s*\n/i, '').replace(/\n```\s*$/i, '')

  return result.trim()
}

export function getThinkingTags(content: string): string {
  if (!content) return ''

  // Extract content from <think>... blocks
  const matches = content.match(/<think>([\s\S]*?)<\/think>/gi)
  if (!matches) return ''

  // Extract inner content and join
  return matches
    .map((match) => {
      // Strip the tags, keep inner content
      return match.replace(/<\/?think(ing)?>/gi, '').trim()
    })
    .filter(Boolean)
    .join('\n\n')
}

export function isThinkingTags(content: string): boolean {
  if (!content) return false
  const trimmed = content.trim()

  // Check if content is ONLY <think>... blocks with no other content
  const withoutThinking = trimmed.replace(/<think>[\s\S]*?<\/think>/gi, '').trim()

  // If removing thinking blocks leaves nothing meaningful, it's thinking-only
  // Whitespace or empty string after stripping means content was only thinking tags
  return withoutThinking === ''
}

/**  * Extract the inner payload(s) of `<html>...</html>` blocks. The chat UI renders each payload as a
 * live sandboxed-iframe block (see ChatView.vue). Multiple blocks are joined with a blank line,
 * mirroring getThinkingTags. Returns '' when no block is present. */
export function getHtmlTags(content: string): string {
  if (!content) return ''

  const matches = content.match(/<html>([\s\S]*?)<\/html>/gi)
  if (!matches) return ''

  return matches
    .map((match) => match.replace(/<\/?html>/gi, '').trim())
    .filter(Boolean)
    .join('\n\n')
}

/** True when the content's only visible payload is `<html>` block(s)
 * (plus optional `<think>` reasoning, which is not visible content). */
export function isHtmlTags(content: string): boolean {
  if (!content) return false
  const trimmed = content.trim()

  const withoutHtml = trimmed.replace(/<html>[\s\S]*?<\/html>/gi, '').trim()
  if (withoutHtml === trimmed) return false // no <html> block at all

  // Remaining text must be think-blocks/whitespace only.
  const withoutThink = withoutHtml.replace(/<think>[\s\S]*?<\/think>/gi, '').trim()
  return withoutThink === ''
}
