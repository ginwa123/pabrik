/** One renderable slice of an assistant turn. `payload` is markdown text, `<html>` inner markup, or
 * Mermaid source — never the wrapper tags themselves. */
export interface RichSegment {
  kind: 'markdown' | 'html' | 'mermaid'
  payload: string
}

/** Every wrapper the response-formatting prompt teaches (`<html>`, `<mermaid>`) plus the ```mermaid
 * fence models reach for anyway. Each alternative pairs a whole-match group with a body group, so
 * one scan yields both the kind and the payload. */
const RICH_BLOCK_SOURCE =
  '(<html>([\\s\\S]*?)<\\/html>)' +
  '|(<mermaid>([\\s\\S]*?)<\\/mermaid>)' +
  '|(```mermaid[ \\t]*\\r?\\n([\\s\\S]*?)```)'

/** Body-group index → kind. */
const BLOCK_KINDS: readonly (readonly [number, 'html' | 'mermaid'])[] = [
  [2, 'html'],
  [4, 'mermaid'],
  [6, 'mermaid'],
]

const SCAN_RE = new RegExp(RICH_BLOCK_SOURCE, 'gi')
/** No `g` flag on purpose: `test()` on a global regex is stateful (lastIndex). */
const DETECT_RE = new RegExp(RICH_BLOCK_SOURCE, 'i')

const prose = (payload: string): RichSegment => ({ kind: 'markdown', payload })

/** True when the turn carries at least one CLOSED `<html>`/`<mermaid>` block or mermaid fence. An
 * unclosed tag mid-stream does not count — it falls through to the legacy markdown path. */
export const hasRichBlocks = (content: string | undefined): boolean =>
  !!content && DETECT_RE.test(content)

/**  * Split a turn into segments in document order, so prose and rich blocks alternate exactly as the
 * model wrote them. Text between (and around) the blocks becomes a `markdown` segment; content with
 * no block yields one markdown segment, so the result is never an empty array. */
export const extractRichBlocks = (content: string): RichSegment[] => {
  const segments: RichSegment[] = []
  let cursor = 0
  SCAN_RE.lastIndex = 0
  let match = SCAN_RE.exec(content)
  while (match !== null) {
    const m = match
    const before = content.slice(cursor, m.index).trim()
    if (before) segments.push(prose(before))
    const hit = BLOCK_KINDS.find(([group]) => m[group] !== undefined)
    if (hit) segments.push({ kind: hit[1], payload: (m[hit[0]] ?? '').trim() })
    cursor = SCAN_RE.lastIndex
    match = SCAN_RE.exec(content)
  }
  const tail = content.slice(cursor).trim()
  if (tail) segments.push(prose(tail))
  if (segments.length === 0) segments.push(prose(''))
  return segments
}
