/**
 * Tests for LoadMemory.vue.
 *
 * Verifies:
 *  - parses the success envelope (query, count, total_count, results)
 *  - parses the error envelope (<error> tag → red border)
 *  - parses per-memory entries (id, tags, timestamps, snippet, optional content)
 *  - snippet [match]…[/match] markers are highlighted as <mark>
 *  - tags are split on "||" into individual chips
 *  - "N of M" badge appears only when paginated (total_count > count)
 *  - "with content" badge appears when with_content="1" was passed
 *  - empty result (count=0) renders "No memories match ..." hint
 *  - click on header toggles expanded state (only when entries or error)
 *  - click on copy-id button copies the id (jsdom stub) without toggling expansion
 *  - per-entry "Show content" toggle reveals optional <content>
 *  - "(truncated)" badge appears when backend cut content at 2 KiB cap
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import LoadMemory from '../LoadMemory.vue'

// ────────────────────────────────────────────────────────────────────────
// jsdom clipboard stub (matches ReadWorkspaceSession.spec.ts pattern)
// ────────────────────────────────────────────────────────────────────────
let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: {
      writeText: vi.fn(async (s: string) => {
        clipboardWrites.push(s)
      }),
    },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
const makeSuccessContent = (
  opts: {
    query?: string
    offset?: number
    limit?: number
    with_content?: '0' | '1'
    count?: number
    total_count?: number
    entries?: Array<{
      id?: string
      tags?: string
      created_at?: string
      updated_at?: string
      snippet?: string
      content?: string
      content_truncated?: boolean
    }>
  } = {},
) => {
  const query = opts.query ?? 'preferred model'
  const offset = opts.offset ?? 0
  const limit = opts.limit ?? 10
  const with_content = opts.with_content ?? '0'
  const count = opts.count ?? opts.entries?.length ?? 0
  const total = opts.total_count ?? count
  const entries = opts.entries ?? []

  const results = entries.map((e) => ({
    id: e.id ?? 'mem_aabbccdd00000000',
    tags: e.tags ?? '',
    created_at: e.created_at ?? '2026-08-06 10:00:00',
    updated_at: e.updated_at ?? '2026-08-06 10:00:00',
    snippet: e.snippet ?? '...[match]preferred[/match] model...',
    content: e.content ?? null,
    truncated: e.content !== undefined ? (e.content_truncated ?? false) : null,
  }))

  return {
    query,
    limit,
    offset,
    with_content: with_content === '1',
    count,
    total_count: total,
    results,
  }
}

const makeErrorContent = (msg = 'query must be non-empty') => ({ error: msg })

const makeEmptyContent = (query = 'no-such-memory') => ({
  query,
  limit: 10,
  offset: 0,
  with_content: false,
  count: 0,
  total_count: 0,
  results: [],
})

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('LoadMemory.vue — happy path', () => {
  it('renders the tool name pill + query + count in the header', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          count: 3,
          entries: [
            { id: 'mem_aaaa000000000001' },
            { id: 'mem_bbbb000000000002' },
            { id: 'mem_cccc000000000003' },
          ],
        }),
      },
    })
    expect(wrapper.find('[data-testid="load-memory"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('load_memory')
    expect(wrapper.text()).toContain('"preferred model"')
    expect(wrapper.text()).toContain('3 hits')
    // No status indicator on success (matches ReadWorkspaceSession pattern —
    // FTS5 result tools don't render a ✓ pill).
    expect(wrapper.text()).not.toContain('Error')
  })

  it('omits the error pill on success', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="load-memory"]').classes()).not.toContain('border-red-500/50')
    expect(wrapper.text()).not.toContain('Error')
  })

  it('does not show red border on success', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="load-memory"]').classes()).not.toContain('border-red-500/50')
  })

  it('does NOT auto-expand', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(false)
  })

  it('renders entry rows when expanded=true', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [
            { id: 'mem_aaaa000000000001', tags: 'preferences||user' },
            { id: 'mem_bbbb000000000002' },
          ],
        }),
        expanded: true,
      },
    })
    const rows = wrapper.findAll('[data-testid="load-memory-entry"]')
    expect(rows.length).toBe(2)
    expect(wrapper.text()).toContain('mem_aaaa000000000001')
    expect(wrapper.text()).toContain('mem_bbbb000000000002')
  })

  it('splits ||-joined tags into individual chips', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [{ id: 'mem_aaaa000000000001', tags: 'preferences||user' }],
        }),
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('preferences')
    expect(wrapper.text()).toContain('user')
    // Two separate chip elements (one per tag).
    const chips = wrapper.findAll('[data-testid="load-memory-entry-tag-0-0"]')
    expect(chips.length).toBe(1)
    expect(chips[0]?.text()).toContain('preferences')
  })

  it('omits tags row when tags is empty', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [{ id: 'mem_aaaa000000000001', tags: '' }],
        }),
        expanded: true,
      },
    })
    expect(wrapper.findAll('[data-testid^="load-memory-entry-tag-"]').length).toBe(0)
  })

  it('renders timestamps when present', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [
            {
              id: 'mem_aaaa000000000001',
              created_at: '2026-08-06 09:00:00',
              updated_at: '2026-08-06 10:00:00',
            },
          ],
        }),
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('created 2026-08-06 09:00:00')
    expect(wrapper.text()).toContain('updated 2026-08-06 10:00:00')
  })

  it('renders snippet with [match]…[/match] markers highlighted as <mark>', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [
            {
              id: 'mem_aaaa000000000001',
              snippet: 'user [match]prefers[/match] the dark theme',
            },
          ],
        }),
        expanded: true,
      },
    })
    // <mark> tag wraps the matched text.
    const marks = wrapper.findAll('[data-testid="load-memory-entry-snippet-0"] mark')
    expect(marks.length).toBe(1)
    expect(marks[0]?.text()).toContain('prefers')
    // The rest of the snippet remains as plain spans.
    expect(wrapper.text()).toContain('user')
    expect(wrapper.text()).toContain('the dark theme')
  })
})

describe('LoadMemory.vue — pagination + with_content badges', () => {
  it('renders "N of M" badge when total_count > count (paginated)', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          count: 10,
          total_count: 47,
          entries: [{ id: 'mem_aabbccdd00000001' }],
        }),
      },
    })
    expect(wrapper.find('[data-testid="load-memory-page-badge"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('10 of 47')
  })

  it('omits "N of M" badge when total_count === count (single page)', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({ count: 3, total_count: 3 }),
      },
    })
    expect(wrapper.find('[data-testid="load-memory-page-badge"]').exists()).toBe(false)
  })

  it('renders "with content" badge when with_content="1"', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [{ id: 'mem_aabbccdd00000001', content: 'full body', content_truncated: false }],
        }),
      },
    })
    expect(wrapper.find('[data-testid="load-memory-with-content-badge"]').exists()).toBe(true)
  })

  it('omits "with content" badge when with_content="0" (default)', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeSuccessContent({ with_content: '0' }) },
    })
    expect(wrapper.find('[data-testid="load-memory-with-content-badge"]').exists()).toBe(false)
  })
})

describe('LoadMemory.vue — full content toggle', () => {
  it('renders "Show content" button when entry has <content>', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [{ id: 'mem_aaaa000000000001', content: 'full memory body here' }],
        }),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="load-memory-entry-toggle-content-0"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Show content')
  })

  it('hides content body until clicked', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [{ id: 'mem_aaaa000000000001', content: 'full body' }],
        }),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="load-memory-entry-content-0"]').exists()).toBe(false)
  })

  it('shows content body after clicking toggle (and label flips to "Hide content")', async () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [{ id: 'mem_aaaa000000000001', content: 'full body' }],
        }),
        expanded: true,
      },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="load-memory-entry-toggle-content-0"]').trigger('click')
    expect(wrapper.find('[data-testid="load-memory-entry-content-0"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Hide content')
    expect(wrapper.text()).toContain('full body')
  })

  it('shows "(truncated)" badge when content_truncated="1"', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [
            {
              id: 'mem_aaaa000000000001',
              content: 'first 2 KiB of a huge memory',
              content_truncated: true,
            },
          ],
        }),
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('(truncated)')
  })

  it('omits "(truncated)" badge when content_truncated="0" or absent', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          with_content: '1',
          entries: [
            { id: 'mem_aaaa000000000001', content: 'short body', content_truncated: false },
          ],
        }),
        expanded: true,
      },
    })
    expect(wrapper.text()).not.toContain('(truncated)')
  })
})

describe('LoadMemory.vue — error path', () => {
  it('renders error message in red', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="load-memory-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('query must be non-empty')
  })

  it('shows the "Error" pill + red border on error', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.text()).toContain('Error')
    expect(wrapper.find('[data-testid="load-memory"]').classes()).toContain('border-red-500/50')
  })
})

describe('LoadMemory.vue — empty result', () => {
  it('renders "No memories match ..." hint', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeEmptyContent('no-such-memory') },
    })
    expect(wrapper.find('[data-testid="load-memory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No memories match "no-such-memory"')
  })

  it('header shows "no hits" when count=0', () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeEmptyContent() },
    })
    expect(wrapper.text()).toContain('no hits')
  })
})

describe('LoadMemory.vue — interaction', () => {
  it('clicking the header toggles expanded state', async () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [{ id: 'mem_aaaa000000000001' }],
        }),
      },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(false)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(true)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(false)
  })

  it('clicking the copy-id button copies the id without toggling expansion', async () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: makeSuccessContent({
          entries: [{ id: 'mem_aaaa000000000001' }],
        }),
        expanded: true,
      },
      attachTo: document.body,
    })

    await wrapper.find('[data-testid="load-memory-entry-copy-0"]').trigger('click')
    expect(clipboardWrites).toEqual(['mem_aaaa000000000001'])
    // Still expanded (the click was stopPropagation'd inside the
    // copy handler, so it didn't bubble to the header).
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(true)

    wrapper.unmount()
  })

  it('does NOT toggle expand when entries are empty (no-op on header click)', async () => {
    const wrapper = mount(LoadMemory, {
      props: { content: makeEmptyContent() },
      attachTo: document.body,
    })
    // Empty + no error → toggle is no-op.
    await wrapper.find('[role="button"]').trigger('click')
    // Empty hint is always visible, but the entries block is NOT.
    expect(wrapper.find('[data-testid="load-memory-entries"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="load-memory-empty"]').exists()).toBe(true)
  })
})
