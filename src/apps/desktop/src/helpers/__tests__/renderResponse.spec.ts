import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock `marked` so the spec can count parse() invocations and avoid the
// real (slow) markdown parser on the hot path. We keep the same return
// shape (`<p>${content}</p>`) so any test that asserts on the HTML
// string doesn't have to special-case the mock.
vi.mock('marked', () => ({
  marked: {
    parse: vi.fn((content: string) => `<p>${content}</p>`),
  },
}))

// Mock the stripTags helpers so the assistant branch doesn't depend on
// the real implementation. We only care that the memoization layer
// routes through them — the actual thinking-tag parsing is covered by
// the existing stripTags tests.
vi.mock('../stripTags', () => ({
  isThinkingTags: (content: string): boolean => content.trim().startsWith('<think>'),
  getThinkingTags: (content: string): string => `<details class="thinking">${content}</details>`,
  stripThinkingTags: (content: string): string => content,
  isHtmlTags: (): boolean => false,
  getHtmlTags: (): string => '',
}))

import { marked } from 'marked'
import { renderResponse, _resetRenderResponseCache } from '../renderResponse'

// renderResponse is rendered into the chat for every visible message
// on every re-render of ChatView. For a long chat (50+ messages) with
// SSE streaming chunks landing every ~100ms, that's O(visible_messages
// × renders_per_second) calls to marked.parse per second — most of
// them returning the same HTML for a message whose content hasn't
// changed. Memoization collapses that to O(unique_messages_per_chat)
// total parse calls (one per message per content mutation), removing
// the visible "scroll jank during long chats" hot path.
//
// 2026-08-27 desktop scroll-perf cross-platform plan, follow-up to
// task_1787761084050_0: the P1+P2 VirtualScroller fixes handled the
// layout-pipeline side; this is the content-pipeline side.

describe('renderResponse memoization', () => {
  beforeEach(() => {
    vi.mocked(marked.parse).mockClear()
    _resetRenderResponseCache()
  })

  it('parses markdown for assistant content', () => {
    const result = renderResponse('hello', 'assistant')
    expect(result).toBe('<p>hello</p>')
    expect(marked.parse).toHaveBeenCalledTimes(1)
  })

  it('returns the same HTML reference for repeated identical content (cache hit)', () => {
    const a = renderResponse('hello', 'assistant')
    const b = renderResponse('hello', 'assistant')
    // `toBe` checks reference equality. The cache returns the same
    // string on every hit, so `a === b` for primitives is the
    // contract. (Strings are value-typed in JS but `===` still works
    // because the cache returns the canonical entry.)
    expect(a).toBe(b)
    expect(marked.parse).toHaveBeenCalledTimes(1)
  })

  it('only invokes marked.parse once for repeated assistant content', () => {
    // The whole point: N renders of the same message = 1 parse.
    for (let i = 0; i < 10; i++) {
      renderResponse('hello', 'assistant')
    }
    expect(marked.parse).toHaveBeenCalledTimes(1)
  })

  it('parses again when the content changes (cache miss)', () => {
    renderResponse('hello', 'assistant')
    renderResponse('world', 'assistant')
    renderResponse('foo bar', 'assistant')
    expect(marked.parse).toHaveBeenCalledTimes(3)
  })

  it('treats leading/trailing whitespace as the same cache entry (after trim)', () => {
    // The function trims `content` at the top; whitespace variants
    // should share a cache entry, otherwise a streaming message
    // would fill the cache with every chunk that happened to have
    // a trailing newline.
    renderResponse('hello', 'assistant')
    renderResponse('  hello  ', 'assistant')
    renderResponse('\nhello\n', 'assistant')
    expect(marked.parse).toHaveBeenCalledTimes(1)
  })

  it('returns empty string for empty content without calling marked.parse', () => {
    const result = renderResponse('', 'assistant')
    expect(result).toBe('')
    expect(marked.parse).not.toHaveBeenCalled()
  })

  it('returns empty string for whitespace-only content without calling marked.parse', () => {
    const result = renderResponse('   \n\t  ', 'assistant')
    expect(result).toBe('')
    expect(marked.parse).not.toHaveBeenCalled()
  })

  it('uses a separate cache slot per role/tool_name (tool branch)', () => {
    // Two tool messages with the same content but different tool_name
    // must NOT share a cache entry — the tool branch produces
    // different HTML for different tools.
    renderResponse('<path>/a</path>', 'tool', 'read_file')
    renderResponse('<path>/a</path>', 'tool', 'glob')
    expect(marked.parse).not.toHaveBeenCalled() // tool branch doesn't use marked
    // The two outputs should differ because read_file renders one
    // summary and glob renders another.
    const a = renderResponse('<path>/a</path>', 'tool', 'read_file')
    const b = renderResponse('<path>/a</path>', 'tool', 'glob')
    expect(a).not.toBe(b)
  })
})

describe('renderResponse mcp_* summary', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  it('summarizes raw MCP output (graphify stats)', () => {
    const out = renderResponse('Nodes: 14885 Edges: 21958', 'tool', 'mcp_graphify_graph_stats')
    expect(out).toContain('mcp_graphify_graph_stats')
    expect(out).toContain('Nodes: 14885')
  })

  it('summarizes any future server (mcp_db_*) the same way', () => {
    const out = renderResponse('{"rows":[]}', 'tool', 'mcp_db_query')
    expect(out).toContain('mcp_db_query')
  })

  it('surfaces the error envelope message', () => {
    const envelope =
      '<tool><name>mcp_db_query</name><parameters>{}</parameters>' +
      '<success>false</success><error>boom</error><data></data></tool>'
    const out = renderResponse(envelope, 'tool', 'mcp_db_query')
    expect(out).toContain('boom')
  })
})

/**
 * The pill for a tool that has NO registered output card.
 *
 * `set_pull_request` was the reported case: the collapsed row read
 * `set_pull_request ✓ {"session_id":"task_…","attached":true,"url":"https://…`
 * — the first 80 characters of the envelope's `data`, which is a summary of
 * nothing. The pill carries the name and status; the payload lives in the
 * expanded body (see `toolPayloadPreview.spec.ts`).
 */
describe('renderResponse unregistered-tool fallback', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  const ENVELOPE = JSON.stringify({
    tool: 'set_pull_request',
    parameters: { pr_url: 'https://github.com/ginwa123/pabrik/pull/922' },
    success: true,
    data: {
      session_id: 'task_1791883461055_3',
      attached: true,
      url: 'https://github.com/ginwa123/pabrik/pull/922',
    },
    error: null,
    v: 1,
  })

  it('never prints the payload of a tool it has no card for', () => {
    // Control: the payload really does contain these strings, so the absence
    // assertions below cannot pass vacuously.
    expect(ENVELOPE).toContain('session_id')
    expect(ENVELOPE).toContain('attached')

    const out = renderResponse(ENVELOPE, 'tool', 'set_pull_request')
    expect(out).toContain('set_pull_request')
    expect(out).toContain('✓')
    expect(out).not.toContain('session_id')
    expect(out).not.toContain('attached')
    expect(out).not.toContain('{')
  })

  it('caps a legacy non-JSON result instead of dumping the whole body', () => {
    // Real shape for the legacy XML rows (`add_element` reaches 52 KB).
    const huge = `<tool><name>add_element</name><data>${'x'.repeat(60_000)}</data></tool>`
    const out = renderResponse(huge, 'tool', 'add_element')
    expect(out).toContain('add_element')
    expect(out.length).toBeLessThan(500)
    expect(out).not.toContain('x'.repeat(200))
  })

  it('keeps the error sentence on failure — that IS the one-line summary', () => {
    const failed = JSON.stringify({
      tool: 'create_kanban_task',
      parameters: {},
      success: false,
      data: null,
      error: 'column "nope" does not exist on this board',
      v: 1,
    })
    const out = renderResponse(failed, 'tool', 'create_kanban_task')
    expect(out).toContain('create_kanban_task')
    expect(out).toContain('✗')
    expect(out).toContain('column "nope" does not exist on this board')
  })

  it('labels an empty tool result instead of rendering an invisible row', () => {
    const out = renderResponse('', 'tool', 'list_secrets')
    expect(out).toContain('list_secrets')
    expect(out).not.toBe('')
  })

  it('still renders nothing for an empty assistant message', () => {
    // The empty-content contract for assistant/user text is unchanged.
    expect(renderResponse('', 'assistant')).toBe('')
    expect(renderResponse('   \n ', 'user')).toBe('')
  })
})
