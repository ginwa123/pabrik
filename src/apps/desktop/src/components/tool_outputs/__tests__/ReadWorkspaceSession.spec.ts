/**
 * Tests for ReadWorkspaceSession.vue.
 *
 * Verifies:
 *  - dispatches correctly between behavior="list" / "search" / "search-within" / "read" / denied / error envelopes
 *  - header summary text reflects behavior, query/session, and count/total_count
 *  - "N of M" badge appears only when total_count > count (paginated)
 *  - search entries render id, role badge, session name, snippet with [match] highlighting
 *  - read entries render id, role badge, preview, and full content toggle
 *    when present (with the truncated attr surfaced as a "(truncated)" label)
 *  - list entries render session name, id, status, message count, preview
 *  - denied envelope renders the denial (never content) with a Denied badge
 *  - error envelope renders the error text in red, hides entries
 *  - empty result renders the per-behavior hint
 *  - click on header toggles expanded state (only when there are entries, an error, a denial, or args)
 *  - copy-id buttons copy the id to clipboard
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import ReadWorkspaceSession from '../ReadWorkspaceSession.vue'

// ────────────────────────────────────────────────────────────────────────
// Test helpers
// ────────────────────────────────────────────────────────────────────────
const makeSearchContent = (
  opts: {
    behavior?: 'search' | 'search-within'
    query?: string
    session_id?: string
    offset?: number
    limit?: number
    count?: number
    total_count?: number
    entries?: Array<{
      id: string
      session_id?: string
      session_name?: string
      role?: string
      created_at?: string
      snippet?: string
    }>
    full_contents?: Array<{
      id: string
      session_id?: string
      role?: string
      content: string
      content_truncated?: boolean
    }>
  } = {},
) => {
  const behavior = opts.behavior ?? 'search'
  const query = opts.query ?? 'login bug'
  const offset = opts.offset ?? 0
  const limit = opts.limit ?? 20
  const count = opts.count ?? opts.entries?.length ?? 0
  const total = opts.total_count ?? count
  const entries = opts.entries ?? []
  const results = entries.map((e) => ({
    id: e.id,
    session_id: e.session_id ?? 's_default',
    session_name: e.session_name ?? 'Default chat',
    role: e.role ?? 'user',
    created_at: e.created_at ?? '2026-01-01 10:00:00',
    // Mirrors what the backend ACTUALLY emits: llm_history.zig calls
    // snippet(messages_fts, 0, '[', ']', '...', 10), which wraps matches in
    // bare brackets. It never emits [match]/[/match].
    snippet: e.snippet ?? '...the login [bug] needs fixing...',
  }))
  return {
    behavior,
    query,
    session_id: opts.session_id ?? null,
    offset,
    limit,
    count,
    total_count: total,
    results,
    // Present only when the caller passed `message_ids`; null otherwise,
    // which is what the backend actually emits.
    full_contents: opts.full_contents ?? null,
  }
}

const makeReadContent = (
  opts: {
    session_id?: string
    order?: 'asc' | 'desc'
    count?: number
    total_count?: number
    entries?: Array<{
      id: string
      role?: string
      created_at?: string
      preview?: string
      tool_call_id?: string
      tool_name?: string
      content?: string
      content_truncated?: boolean
    }>
  } = {},
) => {
  const sid = opts.session_id ?? 's_X'
  const order = opts.order ?? 'asc'
  const count = opts.count ?? opts.entries?.length ?? 0
  const total = opts.total_count ?? count
  const entries = opts.entries ?? []
  const message_index = entries.map((e) => ({
    id: e.id,
    role: e.role ?? 'user',
    created_at: e.created_at ?? '2026-01-01 10:00:00',
    preview: e.preview ?? 'short preview',
    tool_call_id: e.tool_call_id ?? null,
    tool_name: e.tool_name ?? null,
    content: e.content ?? null,
    content_truncated: e.content !== undefined ? (e.content_truncated ?? false) : null,
  }))
  return {
    behavior: 'read',
    order,
    session_id: sid,
    count,
    total_count: total,
    message_index,
  }
}

const makeListContent = (
  opts: {
    count?: number
    total_count?: number
    sessions?: Array<{
      id: string
      name?: string
      status?: string
      message_count?: number
      last_activity?: string
      preview?: string
    }>
  } = {},
) => {
  const sessions = opts.sessions ?? []
  const count = opts.count ?? sessions.length
  const total = opts.total_count ?? count
  const sessionRows = sessions.map((s) => ({
    id: s.id,
    name: s.name ?? s.id,
    status: s.status ?? 'active',
    message_count: s.message_count ?? 3,
    last_activity: s.last_activity ?? '2026-01-01 10:00:00',
    preview: s.preview ?? 'latest human message',
  }))
  return {
    behavior: 'list',
    limit: 50,
    count,
    total_count: total,
    sessions: sessionRows,
  }
}

const makeDeniedContent = (sid = 's_other') => ({
  denied: true,
  session_id: sid,
  message: 'Session is not in your workspace.',
})

const makeErrorContent = (msg = 'Database query failed: SyntaxError') => ({ error: msg })

// ────────────────────────────────────────────────────────────────────────
// jsdom doesn't ship a clipboard by default; provide a minimal stub.
// ────────────────────────────────────────────────────────────────────────
let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  // jsdom doesn't define navigator.clipboard; attach a minimal stub.
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
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('ReadWorkspaceSession.vue — envelope dispatch', () => {
  it('renders behavior="search" header with query + entry count', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: makeSearchContent({
          entries: [{ id: 'h1', snippet: '[match]login bug[/match]' }],
        }),
      },
    })
    expect(wrapper.find('[data-testid="read-workspace-session"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('read_workspace_session')
    expect(wrapper.text()).toContain('workspace search')
    expect(wrapper.text()).toContain('"login bug"')
    expect(wrapper.text()).toContain('1 entry')
  })

  it('renders behavior="read" header with session_id + order', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: makeReadContent({ session_id: 's_long', order: 'desc', entries: [{ id: 'h1' }] }),
      },
    })
    expect(wrapper.text()).toContain('session')
    expect(wrapper.text()).toContain('s_long')
    expect(wrapper.text()).toContain('order=desc')
  })

  it('renders behavior="list" header with session count', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeListContent({ sessions: [{ id: 's_a' }, { id: 's_b' }] }) },
    })
    expect(wrapper.text()).toContain('workspace sessions')
    expect(wrapper.text()).toContain('2 entries')
  })

  it('renders denied envelope with Denied badge, never content', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeDeniedContent('s_other') },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-denied"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Denied')
    expect(wrapper.text()).toContain('s_other')
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      false,
    )
    expect(wrapper.find('[data-testid="read-workspace-session-read-entries"]').exists()).toBe(false)
  })

  it('renders error envelope with red border + error text', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeErrorContent('Not linked to any workspace') },
    })
    expect(wrapper.find('[data-testid="read-workspace-session"]').classes()).toContain(
      'border-red-500/50',
    )
    expect(wrapper.find('[data-testid="read-workspace-session-error"]').text()).toContain(
      'Not linked to any workspace',
    )
    // No entry list rendered.
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      false,
    )
    expect(wrapper.find('[data-testid="read-workspace-session-read-entries"]').exists()).toBe(false)
  })
})

describe('ReadWorkspaceSession.vue — pagination badge', () => {
  it('shows "N of M" badge only when total_count > count (paginated)', () => {
    // Paginated: 2 of 5 returned
    const paginated = mount(ReadWorkspaceSession, {
      props: {
        content: makeSearchContent({
          count: 2,
          total_count: 5,
          entries: [{ id: 'h1' }, { id: 'h2' }],
        }),
      },
    })
    const badge = paginated.find('[data-testid="read-workspace-session-page-badge"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toBe('2 of 5')

    // Not paginated: all 5 fit in one page — no badge
    const full = mount(ReadWorkspaceSession, {
      props: {
        content: makeSearchContent({
          count: 5,
          total_count: 5,
          entries: [{ id: 'h1' }, { id: 'h2' }, { id: 'h3' }, { id: 'h4' }, { id: 'h5' }],
        }),
      },
    })
    expect(full.find('[data-testid="read-workspace-session-page-badge"]').exists()).toBe(false)
    expect(full.text()).toContain('5 entries')
  })
})

describe('ReadWorkspaceSession.vue — search entries', () => {
  it('renders one <li> per entry with role badge, id, session name, snippet', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [
            {
              id: 'h1',
              role: 'user',
              session_id: 's_42',
              session_name: 'Auth work',
              snippet: 'fix [match]login bug[/match]',
            },
            {
              id: 'h2',
              role: 'assistant',
              session_id: 's_42',
              session_name: 'Auth work',
              snippet: '[match]login[/match] confirmed',
            },
          ],
        }),
      },
    })
    const entries = wrapper.findAll('[data-testid="read-workspace-session-search-entry"]')
    expect(entries.length).toBe(2)

    expect(entries[0]!.text()).toContain('user')
    expect(entries[0]!.text()).toContain('h1')
    expect(entries[0]!.text()).toContain('login bug')
    // The session name now lives on the group header, not on every row —
    // it was repeated on each of 11,996 rows before.
    expect(entries[0]!.text()).not.toContain('Auth work')
    expect(wrapper.find('.search-group-header').text()).toContain('Auth work')
  })

  it('highlights bare-bracket spans (the format the backend actually emits)', () => {
    // llm_history.zig calls snippet(messages_fts, 0, '[', ']', '...', 10), so a real snippet looks
    // like `...a [portal] that refuses...` — there are no `[match]`/`[/match]` tags in it. This is
    // a verbatim capture from the live database.
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [
            {
              id: 'h1',
              snippet: "...error: 'linux.file [dialog].test.a [portal] that refuses the...",
            },
          ],
        }),
      },
    })
    const snippetEl = wrapper.find('[data-testid="search-entry-snippet-0"]')
    expect(snippetEl.exists()).toBe(true)

    const marks = snippetEl.findAll('mark')
    expect(marks.map((m) => m.text())).toEqual(['dialog', 'portal'])
    // The brackets themselves must not survive into the rendered text.
    expect(snippetEl.text()).not.toContain('[dialog]')
    expect(snippetEl.text()).not.toContain('[portal]')
  })

  it('still highlights legacy [match]...[/match] snippets from older transcripts', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [{ id: 'h1', snippet: 'pre [match]login bug[/match] post' }],
        }),
      },
    })
    const snippetEl = wrapper.find('[data-testid="search-entry-snippet-0"]')
    expect(snippetEl.html()).toContain('<mark')
    expect(snippetEl.html()).toContain('login bug')
    expect(snippetEl.text()).not.toContain('[match]')
  })

  it('does not swallow content when a match contains a nested bracket', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [{ id: 'h1', snippet: 'x [xdg-[portal] y [dialog] z' }],
        }),
      },
    })
    const snippetEl = wrapper.find('[data-testid="search-entry-snippet-0"]')
    // The text after the nested-bracket term must still be visible.
    expect(snippetEl.text()).toContain('z')
    expect(snippetEl.text()).toContain('dialog')
  })

  it('groups search hits by session, newest conversation first', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [
            {
              id: 'h1',
              role: 'user',
              session_id: 's_old',
              session_name: 'Older chat',
              created_at: '2026-01-01 10:00:00',
            },
            {
              id: 'h2',
              role: 'user',
              session_id: 's_new',
              session_name: 'Newer chat',
              created_at: '2026-03-01 10:00:00',
            },
            {
              id: 'h3',
              role: 'assistant',
              session_id: 's_old',
              session_name: 'Older chat',
              created_at: '2026-02-01 10:00:00',
            },
          ],
        }),
      },
    })
    const groups = wrapper.findAll('.search-group')
    // Two sessions, so two groups.
    expect(groups).toHaveLength(2)
    // Ordered by newest hit: s_new (March) before s_old (Feb).
    expect(groups[0]!.text()).toContain('Newer chat')
    expect(groups[0]!.text()).toContain('1 hit')
    expect(groups[1]!.text()).toContain('Older chat')
    expect(groups[1]!.text()).toContain('2 hits')
    // All three entries still render.
    expect(wrapper.findAll('[data-testid="read-workspace-session-search-entry"]')).toHaveLength(3)
  })

  it('groups hits with no session_id without throwing', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: {
          behavior: 'search',
          query: 'x',
          count: 1,
          total_count: 1,
          results: [
            { id: 'h9', role: 'user', session_id: '', session_name: '', snippet: 'a [b] c' },
          ],
        },
      },
    })
    const group = wrapper.find('[data-testid="search-group-none"]')
    expect(group.exists()).toBe(true)
    expect(group.text()).toContain('(no session)')
    // A nameless group offers no open affordance.
    expect(wrapper.find('[data-testid="search-group-open-none"]').element.tagName).toBe('SPAN')
  })

  it('emits openSession when a session group header is clicked', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [
            { id: 'h1', session_id: 's_42', session_name: 'Auth work' },
            { id: 'h2', session_id: 's_99', session_name: 'Other work' },
          ],
        }),
      },
    })
    await wrapper.find('[data-testid="search-group-open-s_42"]').trigger('click')
    expect(wrapper.emitted('openSession')).toEqual([['s_42']])
  })

  it('renders a role facet footer scoped to the current page', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          total_count: 11996,
          entries: [
            { id: 'h1', role: 'tool' },
            { id: 'h2', role: 'tool' },
            { id: 'h3', role: 'user' },
          ],
        }),
      },
    })
    const footer = wrapper.find('[data-testid="read-workspace-session-role-facets"]')
    expect(footer.exists()).toBe(true)
    expect(footer.text()).toContain('in this page')
    expect(footer.find('[data-testid="role-facet-tool"]').text()).toContain('tool 2')
    expect(footer.find('[data-testid="role-facet-user"]').text()).toContain('user 1')
    // The page total is explicit so a page count is never read as a total.
    expect(footer.text()).toContain('3 of 11996')
  })

  it('copies a ready-made role-filtered tool call when a facet is clicked', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          query: 'portal dialog',
          entries: [{ id: 'h1', role: 'user' }],
        }),
      },
    })
    await wrapper.find('[data-testid="role-facet-user"]').trigger('click')
    expect(clipboardWrites).toContain('{"query":"portal dialog","role":"user"}')
  })

  it('renders full_contents bodies behind a toggle', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeSearchContent({
          entries: [{ id: 'h1', role: 'user' }],
          full_contents: [
            {
              id: 'h1',
              session_id: 's_42',
              role: 'user',
              content: 'the whole body',
              content_truncated: true,
            },
          ],
        }),
      },
    })

    const pre = wrapper.find('[data-testid="search-entry-content-0"]')
    expect(pre.exists()).toBe(false)
    // The truncation flag is visible before expanding.
    expect(wrapper.find('[data-testid="search-entry-toggle-full-0"]').text()).toContain(
      '(truncated)',
    )

    await wrapper.find('[data-testid="search-entry-toggle-full-0"]').trigger('click')
    const after = wrapper.find('[data-testid="search-entry-content-0"]')
    expect(after.exists()).toBe(true)
    expect(after.text()).toContain('the whole body')
  })

  it('renders no content toggle when full_contents is absent', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { expanded: true, content: makeSearchContent({ entries: [{ id: 'h1' }] }) },
    })
    expect(wrapper.find('[data-testid="search-entry-full-0"]').exists()).toBe(false)
  })

  it('renders the empty-results hint when search matches nothing', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: makeSearchContent({
          query: 'no-such-string',
          count: 0,
          total_count: 0,
          entries: [],
        }),
      },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-empty"]').text()).toContain(
      'No matches for "no-such-string"',
    )
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      false,
    )
  })
})

describe('ReadWorkspaceSession.vue — read entries', () => {
  it('renders role badge, id, preview, and tool_call_id/tool_name for tool-role entries', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeReadContent({
          entries: [
            { id: 'h_user', role: 'user', preview: 'fix the login bug' },
            {
              id: 'h_tool',
              role: 'tool',
              preview: 'bash output',
              tool_call_id: 'call_123',
              tool_name: 'bash',
            },
          ],
        }),
      },
    })
    const entries = wrapper.findAll('[data-testid="read-workspace-session-read-entry"]')
    expect(entries.length).toBe(2)
    expect(entries[1]!.text()).toContain('tool')
    expect(entries[1]!.text()).toContain('call_123')
    expect(entries[1]!.text()).toContain('bash')
  })

  it('hides the full <content> by default; toggle button expands it', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeReadContent({
          entries: [
            {
              id: 'h_full',
              role: 'assistant',
              content: 'this is the full body',
              content_truncated: false,
            },
          ],
        }),
      },
    })
    // Content body should be hidden initially.
    expect(wrapper.find('[data-testid="read-entry-content-0"]').exists()).toBe(false)
    // Click the toggle.
    await wrapper.find('[data-testid="read-entry-toggle-content-0"]').trigger('click')
    expect(wrapper.find('[data-testid="read-entry-content-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="read-entry-content-0"]').text()).toBe(
      'this is the full body',
    )
  })

  it('shows "(truncated)" label when content_truncated is true', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeReadContent({
          entries: [
            { id: 'h_full', role: 'assistant', content: 'first 16 KB...', content_truncated: true },
          ],
        }),
      },
    })
    const toggle = wrapper.find('[data-testid="read-entry-toggle-content-0"]')
    expect(toggle.exists()).toBe(true)
    expect(toggle.text()).toContain('(truncated)')
  })

  it('renders the empty-results hint when session has 0 messages', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: makeReadContent({ session_id: 's_empty', count: 0, total_count: 0, entries: [] }),
      },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-empty"]').text()).toContain(
      'No messages in s_empty',
    )
    expect(wrapper.find('[data-testid="read-workspace-session-read-entries"]').exists()).toBe(false)
  })
})

describe('ReadWorkspaceSession.vue — list entries', () => {
  it('renders one <li> per session with name, id, status, count, preview', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        expanded: true,
        content: makeListContent({
          sessions: [
            {
              id: 's_a',
              name: 'Auth work',
              status: 'active',
              message_count: 12,
              preview: 'fix the login',
            },
            { id: 's_b', name: 'Deploy', status: 'archived', message_count: 4, preview: 'ship it' },
          ],
        }),
      },
    })
    const entries = wrapper.findAll('[data-testid="read-workspace-session-list-entry"]')
    expect(entries.length).toBe(2)
    expect(entries[0]!.text()).toContain('Auth work')
    expect(entries[0]!.text()).toContain('s_a')
    expect(entries[0]!.text()).toContain('12 msgs')
    expect(entries[0]!.text()).toContain('fix the login')
  })

  it('renders the empty hint when the workspace has no other sessions', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeListContent({ count: 0, total_count: 0, sessions: [] }) },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-empty"]').text()).toContain(
      'No other sessions in your workspace',
    )
  })
})

describe('ReadWorkspaceSession.vue — interactions', () => {
  it('clicking the header toggles expanded state when entries are present', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeSearchContent({ entries: [{ id: 'h1' }] }) },
    })
    // Collapsed by default; toggle the header to expand.
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      false,
    )
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      true,
    )
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      false,
    )
  })

  it('starts in expanded state when `expanded` prop is true', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { content: makeSearchContent({ entries: [{ id: 'h1' }] }), expanded: true },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-search-entries"]').exists()).toBe(
      true,
    )
  })

  it('copy-id button writes the message id to the clipboard', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: { expanded: true, content: makeReadContent({ entries: [{ id: 'h_42_unique' }] }) },
    })
    await wrapper.find('.copy-btn').trigger('click')
    expect(clipboardWrites).toContain('h_42_unique')
  })
})
