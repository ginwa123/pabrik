/** Tests for ReadCompactedMessages.vue — the chat-bubble renderer for the
 * `<read_compacted_messages>` envelope returned by the `read_compacted_messages` tool. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import ReadCompactedMessages from '../components/tool_outputs/ReadCompactedMessages.vue'

const FULL_INDEX_ENVELOPE = {
  mode: 'index',
  session_id: 'task_1782443377620',
  count: 3,
  message_index: [
    { id: 'h_001', role: 'user', created_at: '2025-01-15 12:34:56', preview: 'Fix the login bug' },
    { id: 'h_002', role: 'assistant', created_at: '2025-01-15 12:35:10', preview: 'Investigating the auth flow' },
    {
      id: 'h_003',
      role: 'tool',
      created_at: '2025-01-15 12:36:02',
      preview: 'tests pass: 42/42',
      tool_call_id: 'tc_bash_1',
      tool_name: 'bash',
    },
  ],
}

const FULL_MODE_ENVELOPE = {
  mode: 'full',
  session_id: 'sess_xyz',
  count: 1,
  message_index: [
    {
      id: 'h_999',
      role: 'user',
      created_at: '2025-02-01 09:00:00',
      preview: 'long question preview',
      content: 'Full user content body that is only present in mode=full',
    },
  ],
}

const ERROR_ENVELOPE = { error: 'Database query failed: TableNotFound' }

const EMPTY_INDEX_ENVELOPE = { mode: 'index', session_id: 'sess_empty', count: 0, message_index: [] }

describe('ReadCompactedMessages', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  // ── Header / summary ───────────────────────────────────────────────────
  it('renders the tool name + mode + count + session_id in the header', () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE },
    })
    const text = wrapper.text()
    expect(text).toContain('read_compacted_messages')
    expect(text).toContain('index mode')
    expect(text).toContain('3 messages')
    expect(text).toContain('task_1782443377620')
  })

  it('uses singular "message" when count is exactly 1', () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_MODE_ENVELOPE },
    })
    const text = wrapper.text()
    expect(text).toContain('1 message')
    expect(text).not.toContain('1 messages')
    expect(text).toContain('full mode')
  })

  it('respects the `expanded` prop (renders entries when true)', () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE, expanded: true },
    })
    const entries = wrapper.findAll('[data-testid="rcm-entry"]')
    expect(entries).toHaveLength(3)
  })

  it('collapses by default and reveals entries on header click', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE },
    })
    // Collapsed by default: entries are not yet rendered (v-if on the
    // wrapper that contains the entries list).
    expect(wrapper.find('[data-testid="rcm-entries"]').exists()).toBe(false)

    // Click the header to expand.
    const header = wrapper.find('[role="button"]')
    expect(header.exists()).toBe(true)
    await header.trigger('click')

    expect(wrapper.find('[data-testid="rcm-entries"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="rcm-entry"]')).toHaveLength(3)
  })

  // ── Entry rendering ────────────────────────────────────────────────────
  it('renders id, role, created_at, and preview for each entry', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE, expanded: true },
    })
    const first = wrapper.findAll('[data-testid="rcm-entry"]')[0]
    if (!first) throw new Error('expected first entry')
    expect(first.text()).toContain('user')
    expect(first.text()).toContain('h_001')
    expect(first.text()).toContain('2025-01-15 12:34:56')
    expect(first.text()).toContain('Fix the login bug')
  })

  it('surfaces tool_call_id and tool_name as pills for tool-role entries', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE, expanded: true },
    })
    const toolEntry = wrapper.findAll('[data-testid="rcm-entry"]')[2]
    if (!toolEntry) throw new Error('expected third entry')
    expect(toolEntry.text()).toContain('tool')
    expect(toolEntry.find('[data-testid="rcm-entry-tool-call-id"]').exists()).toBe(true)
    expect(toolEntry.find('[data-testid="rcm-entry-tool-name"]').exists()).toBe(true)
    expect(toolEntry.text()).toContain('tc_bash_1')
    expect(toolEntry.text()).toContain('bash')
  })

  it('does not render tool_call_id / tool_name pills for non-tool entries', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE, expanded: true },
    })
    const userEntry = wrapper.findAll('[data-testid="rcm-entry"]')[0]
    const assistantEntry = wrapper.findAll('[data-testid="rcm-entry"]')[1]
    if (!userEntry || !assistantEntry) throw new Error('expected 2 entries')
    expect(userEntry.find('[data-testid="rcm-entry-tool-call-id"]').exists()).toBe(false)
    expect(assistantEntry.find('[data-testid="rcm-entry-tool-name"]').exists()).toBe(false)
  })

  it('applies role-* CSS class on each entry badge', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_INDEX_ENVELOPE, expanded: true },
    })
    const entries = wrapper.findAll('[data-testid="rcm-entry"]')
    expect(entries[0]?.find('[data-testid="rcm-entry-role"]').classes()).toContain('role-user')
    expect(entries[1]?.find('[data-testid="rcm-entry-role"]').classes()).toContain('role-assistant')
    expect(entries[2]?.find('[data-testid="rcm-entry-role"]').classes()).toContain('role-tool')
  })

  // ── Full-mode content ──────────────────────────────────────────────────
  it('renders a "Show content" toggle when entry.content is present (mode=full)', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: FULL_MODE_ENVELOPE, expanded: true },
    })
    const entry = wrapper.find('[data-testid="rcm-entry"]')
    const toggle = entry.find('[data-testid="rcm-toggle-content-h_999"]')
    expect(toggle.exists()).toBe(true)
    expect(toggle.text()).toContain('Show content')

    // Content body hidden by default.
    expect(wrapper.find('[data-testid="rcm-entry-content"]').exists()).toBe(false)

    await toggle.trigger('click')
    expect(toggle.text()).toContain('Hide content')
    const body = wrapper.find('[data-testid="rcm-entry-content"]')
    expect(body.exists()).toBe(true)
    expect(body.text()).toContain('Full user content body')
  })

  // ── Error state ────────────────────────────────────────────────────────
  it('renders error state when <error>...</error> is present', () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: ERROR_ENVELOPE },
    })
    const text = wrapper.text()
    expect(text).toContain('Database query failed: TableNotFound')
    // The "Error" pill should appear in the header.
    expect(wrapper.text()).toContain('Error')
    // The expanded error body is reachable on click.
    const header = wrapper.find('[role="button"]')
    void header.trigger('click')
  })

  it('shows error body when expanded', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: ERROR_ENVELOPE },
    })
    const header = wrapper.find('[role="button"]')
    await header.trigger('click')
    const errorBody = wrapper.find('[data-testid="rcm-error"]')
    expect(errorBody.exists()).toBe(true)
    expect(errorBody.text()).toContain('Database query failed: TableNotFound')
  })

  // ── Empty (0 entries) state ────────────────────────────────────────────
  it('renders an empty-state placeholder when count is 0', async () => {
    wrapper = mount(ReadCompactedMessages, {
      props: { content: EMPTY_INDEX_ENVELOPE, expanded: true },
    })
    expect(wrapper.find('[data-testid="rcm-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No messages found')
    // No entry <li> rendered.
    expect(wrapper.findAll('[data-testid="rcm-entry"]')).toHaveLength(0)
  })
})