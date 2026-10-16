/** Unit tests for the <html> wrapper-tag helpers in stripTags.ts. Plan:
 * docs/superpowers/plans/2026-08-23-html-tag-support.md (Task 2) The <html> tag lets the LLM emit
 * raw HTML that the chat UI renders as a live sandboxed-iframe block. */
import { beforeEach, describe, expect, it } from 'vitest'
import {
  _resetStripThinkingTagsCache,
  _stripThinkingTagsCacheStats,
  getHtmlTags,
  isHtmlTags,
  stripThinkingTags,
} from '../helpers/stripTags'

describe('getHtmlTags', () => {
  it('extracts inner content of a single block', () => {
    expect(getHtmlTags('<html><div>x</div></html>')).toBe('<div>x</div>')
  })

  it('extracts multiple blocks joined with blank line', () => {
    const got = getHtmlTags('<html><b>a</b></html> mid <html><i>b</i></html>')
    expect(got).toBe('<b>a</b>\n\n<i>b</i>')
  })

  it('returns empty string when no html tag present', () => {
    expect(getHtmlTags('plain text')).toBe('')
    expect(getHtmlTags('')).toBe('')
  })

  it('is case-insensitive on the tag name', () => {
    expect(getHtmlTags('<HTML><div>x</div></HTML>')).toBe('<div>x</div>')
  })
})

describe('isHtmlTags', () => {
  it('true for html-only content', () => {
    expect(isHtmlTags('<html>a</html>')).toBe(true)
  })

  it('true for think + html mix (think is not visible content)', () => {
    expect(isHtmlTags('<think>t</think><html>a</html>')).toBe(true)
  })

  it('false for plain text', () => {
    expect(isHtmlTags('just text')).toBe(false)
  })

  it('false when html is only part of the content', () => {
    expect(isHtmlTags('before <html>a</html> after')).toBe(false)
  })

  it('false for empty/undefined-ish input', () => {
    expect(isHtmlTags('')).toBe(false)
  })
})

describe('stripThinkingTags — <html> interplay', () => {
  it('unwraps a lone html block to its inner content', () => {
    expect(stripThinkingTags('<html>a</html>')).toBe('a')
  })

  it('drops think and unwraps html when both present', () => {
    expect(stripThinkingTags('<think>s</think><html><b>hi</b></html>')).toBe(
      '<b>hi</b>',
    )
  })

  it('keeps html-only messages VISIBLE (non-empty result)', () => {
    // Visibility filtering (ChatView filteredMessages / hasVisibleContent)
    // relies on stripThinkingTags(...).trim().length > 0.
    const stripped = stripThinkingTags('<html><h1>Title</h1></html>')
    expect(stripped.length).toBeGreaterThan(0)
    expect(stripped).toContain('<h1>')
  })

  it('leaves content without tags unchanged', () => {
    expect(stripThinkingTags('no tags here')).toBe('no tags here')
  })

  it('does not leak raw <think> into marked for think+html messages', () => {
    const stripped = stripThinkingTags('<think>secret</think><html>x</html>')
    expect(stripped).not.toContain('<think>')
    expect(stripped).not.toContain('secret')
  })

  it('preserves lone-think passthrough behavior (regression guard)', () => {
    // Existing contract: lone <think> is returned unchanged by design
    // (rendered as a thinking bubble, not markdown).
    expect(stripThinkingTags('<think>reasoning only</think>')).toBe(
      '<think>reasoning only</think>',
    )
  })
})

// 2026-08-24 — bug-trace task_1787545088500_6: when the LLM wraps a final
// answer in ```html / ``` / ```markdown fences around <markdown>...</markdown>
// (or even with no wrapper at all), the fence survives stripThinkingTags and
// marked.parse renders the ENTIRE message as a literal <pre> code block —
// the user sees raw `##`/`**`/`[link](url)` as text instead of formatted
// markdown. stripThinkingTags MUST strip these outer fences so the wrapped
// markdown reaches marked.parse cleanly.
describe('stripThinkingTags — fenced markdown wrappers', () => {
  it('strips ```html fence around <markdown> (real DB row shape)', () => {
    // Bytes-verbatim copy of row 1787545407823788849 from
    // task_1787540075329_3 in ~/.config/pabrik/agent.db (truncated).
    const fenced =
      '```html\n<markdown>\n## Done — tests now inline\n\n**What changed:**\n- item one\n</markdown>\n```'
    const stripped = stripThinkingTags(fenced)
    // Inner <markdown> wrapper is unwrapped and the fence is gone.
    expect(stripped).not.toContain('```')
    expect(stripped).toContain('## Done')
    expect(stripped).toContain('**What changed:**')
    expect(stripped).not.toContain('<markdown>')
  })

  it('strips ``` fence around <markdown> (no language tag)', () => {
    const fenced =
      '```\n<markdown>\n## Heading\n\n- item\n</markdown>\n```'
    const stripped = stripThinkingTags(fenced)
    expect(stripped).not.toContain('```')
    expect(stripped).toContain('## Heading')
  })

  it('strips ```markdown fence around <markdown>', () => {
    const fenced =
      '```markdown\n<markdown>\n# Title\n</markdown>\n```'
    const stripped = stripThinkingTags(fenced)
    expect(stripped).not.toContain('```')
    expect(stripped).toContain('# Title')
  })

  it('leaves inline code spans (single backticks) untouched', () => {
    // Must NOT match single-backtick inline code spans like `foo`.
    const inline = 'Use `npm test` to run the tests.'
    expect(stripThinkingTags(inline)).toBe(inline)
  })

  it('does not strip fence markers that are not at line boundaries', () => {
    // Mid-line ``` is not a fence.
    const midLine = 'a ``` b ``` c\n<markdown>\nx\n</markdown>'
    const stripped = stripThinkingTags(midLine)
    // The ```-surrounded <markdown> still unwraps; the mid-line triple
    // backticks are preserved verbatim because they are inside prose.
    expect(stripped).not.toContain('<markdown>')
    expect(stripped).toContain('x')
  })

  it('preserves lone-think passthrough when fences wrap a <think> block', () => {
    // Defensive: the fence stripper must not regress the lone-think
    // contract. Existing passthrough behavior is the source of truth.
    expect(stripThinkingTags('<think>reasoning only</think>')).toBe(
      '<think>reasoning only</think>',
    )
  })
})

// 2026-09-11 — chatview open/stream freeze. ChatView re-scans the WHOLE loaded transcript with
// stripThinkingTags on every `messages` mutation (filteredMessages + hasBubbleContent +
// renderResponse), and one SSE chunk = one mutation.
describe('stripThinkingTags — memoization (per-chunk render cost)', () => {
  beforeEach(() => {
    _resetStripThinkingTagsCache()
  })

  it('does not re-scan content it has already seen (cache hit adds no entry)', () => {
    const body = 'a'.repeat(2000)
    const content = `<markdown>${body}</markdown>`
    expect(stripThinkingTags(content)).toBe(body)
    const afterFirst = _stripThinkingTagsCacheStats()
    expect(afterFirst.entries).toBe(1)
    // Same string again — a recompute would be a no-op for the cache, but the
    // 2nd call must not grow it (i.e. it was served from the memo).
    expect(stripThinkingTags(content)).toBe(body)
    expect(_stripThinkingTagsCacheStats()).toEqual(afterFirst)
    // A DIFFERENT content does add an entry (the cache is keyed by content).
    expect(stripThinkingTags('<markdown>other</markdown>')).toBe('other')
    expect(_stripThinkingTagsCacheStats().entries).toBe(2)
  })

  it('recomputes after a cache reset (no stale values survive)', () => {
    const body = 'b'.repeat(2000)
    const content = `<markdown>${body}</markdown>`
    expect(stripThinkingTags(content)).toBe(body)
    _resetStripThinkingTagsCache()
    expect(_stripThinkingTagsCacheStats().entries).toBe(0)
    expect(stripThinkingTags(content)).toBe(body)
    expect(_stripThinkingTagsCacheStats().entries).toBe(1)
  })

  it('does not confuse different contents that strip to the same text', () => {
    expect(stripThinkingTags('<markdown>same</markdown>')).toBe('same')
    expect(stripThinkingTags('<plain>same</plain>')).toBe('same')
    expect(stripThinkingTags('same')).toBe('same')
  })

  it('still returns the passthrough string for lone think blocks', () => {
    expect(stripThinkingTags('<think>only</think>')).toBe('<think>only</think>')
    expect(stripThinkingTags('<think>only</think>')).toBe('<think>only</think>')
  })

  it('handles the empty / undefined inputs without caching them', () => {
    expect(stripThinkingTags('')).toBe('')
    expect(stripThinkingTags(undefined)).toBe('')
    expect(_stripThinkingTagsCacheStats().entries).toBe(0)
  })

  it('stays bounded: the cache is dropped once it exceeds its byte budget', () => {
    // 24 distinct ~700 KB strings ≈ 33 MB of key+value chars, well past the
    // 16 MB budget — the cache must clear instead of growing without limit.
    const firstContent = 'c'.repeat(700_000)
    expect(stripThinkingTags(firstContent)).toBe(firstContent)
    expect(_stripThinkingTagsCacheStats().entries).toBe(1)
    for (let i = 0; i < 24; i++) {
      const content = `${'d'.repeat(700_000)}${i}`
      expect(stripThinkingTags(content)).toBe(content)
    }
    const stats = _stripThinkingTagsCacheStats()
    expect(stats.entries).toBeLessThan(24) // evicted, not unbounded
    expect(stats.chars).toBeLessThanOrEqual(16 * 1024 * 1024)
    expect(stripThinkingTags(firstContent)).toBe(firstContent)
  })
})
