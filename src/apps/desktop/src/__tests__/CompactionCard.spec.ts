/**
 * Tests for CompactionCard.vue — the chat-bubble renderer for the
 * `<compact_messages>` envelope that `compactMessageInMemoryNew` writes
 * to the DB. The component is purely presentational (parses a string,
 * no API calls), so no mocks are needed.
 *
 * Mirrors the style of `SetGitWorktree.spec.ts`.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import CompactionCard from '../components/preview/CompactionCard.vue'

const FULL_ENVELOPE = `<compact_messages>
  <metadata>
    <session_id>sess_abc123</session_id>
    <model>gpt-4o</model>
    <compacted_at>2025-01-15 12:34:56</compacted_at>
    <original_count>42</original_count>
  </metadata>
  <message_index>
    <entry>
      <id>h_001</id>
      <role>user</role>
      <preview>Fix the login bug</preview>
    </entry>
    <entry>
      <id>h_002</id>
      <role>assistant</role>
      <preview>Investigating the auth flow</preview>
    </entry>
    <entry>
      <id>h_003</id>
      <role>tool</role>
      <preview>tests pass: 42/42</preview>
      <tool_call_id>tc_bash_1</tool_call_id>
      <tool_name>bash</tool_name>
    </entry>
  </message_index>
  <summary>GOAL: fix login
NEXT ACTION: deploy</summary>
</compact_messages>`

describe('CompactionCard', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the card header with title and message count', () => {
    wrapper = mount(CompactionCard, { props: { content: FULL_ENVELOPE } })
    expect(wrapper.text()).toContain('Conversation Compaction')
    expect(wrapper.text()).toContain('3 messages compacted')
  })

  it('renders the metadata section with session_id, model, and timestamp', () => {
    wrapper = mount(CompactionCard, { props: { content: FULL_ENVELOPE } })
    const metadata = wrapper.find('[data-testid="compaction-metadata"]')
    expect(metadata.exists()).toBe(true)
    expect(metadata.text()).toContain('sess_abc123')
    expect(metadata.text()).toContain('gpt-4o')
    expect(metadata.text()).toContain('2025-01-15 12:34:56')
  })

  it('renders one row per dropped message in the index', () => {
    wrapper = mount(CompactionCard, { props: { content: FULL_ENVELOPE } })
    const entries = wrapper.findAll('[data-testid="compaction-entry"]')
    expect(entries).toHaveLength(3)
    const first = entries[0]
    const second = entries[1]
    const third = entries[2]
    if (!first || !second || !third) throw new Error('expected 3 entries')
    // First entry: user role
    expect(first.text()).toContain('Fix the login bug')
    // Second entry: assistant role
    expect(second.text()).toContain('Investigating the auth flow')
    // Third entry: tool role, with tool_call_id surfaced as a separate badge
    expect(third.text()).toContain('tests pass: 42/42')
    expect(third.text()).toContain('tc_bash_1')
  })

  it('uses role-specific styling (role-* class) on each entry', () => {
    wrapper = mount(CompactionCard, { props: { content: FULL_ENVELOPE } })
    const entries = wrapper.findAll('[data-testid="compaction-entry"]')
    const first = entries[0]
    const second = entries[1]
    const third = entries[2]
    if (!first || !second || !third) throw new Error('expected 3 entries')
    expect(first.classes()).toContain('entry-role-user')
    expect(second.classes()).toContain('entry-role-assistant')
    expect(third.classes()).toContain('entry-role-tool')
  })

  it('hides the summary content by default and reveals it on click', async () => {
    wrapper = mount(CompactionCard, { props: { content: FULL_ENVELOPE } })
    // Summary <pre> not rendered until expanded
    expect(wrapper.find('[data-testid="compaction-summary-content"]').exists()).toBe(false)
    // Toggle text shows the right hint
    expect(wrapper.find('[data-testid="compaction-summary-toggle"]').text()).toContain('click to expand')
    // Click → expand
    await wrapper.find('[data-testid="compaction-summary-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="compaction-summary-content"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="compaction-summary-content"]').text()).toContain('GOAL: fix login')
    // Hint flips
    expect(wrapper.find('[data-testid="compaction-summary-toggle"]').text()).toContain('click to collapse')
  })

  it('handles a missing summary section gracefully (no toggle, no error)', () => {
    const noSummary = `<compact_messages>
      <metadata><session_id>s1</session_id></metadata>
      <message_index>
        <entry><id>h1</id><role>user</role><preview>only message</preview></entry>
      </message_index>
    </compact_messages>`
    wrapper = mount(CompactionCard, { props: { content: noSummary } })
    expect(wrapper.find('[data-testid="compaction-summary"]').exists()).toBe(false)
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(1)
  })

  it('handles a missing metadata section gracefully (no metadata block)', async () => {
    const noMetadata = `<compact_messages>
      <message_index>
        <entry><id>h1</id><role>user</role><preview>only message</preview></entry>
      </message_index>
      <summary>just a summary</summary>
    </compact_messages>`
    wrapper = mount(CompactionCard, { props: { content: noMetadata } })
    expect(wrapper.find('[data-testid="compaction-metadata"]').exists()).toBe(false)
    // The summary is collapsed by default; expand it before checking the body
    await wrapper.find('[data-testid="compaction-summary-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="compaction-summary-content"]').text()).toContain('just a summary')
  })

  it('handles malformed XML by rendering an empty card (no crash)', () => {
    const malformed = `<compact_messages><metadata><session_id>s1</unclosed>`
    wrapper = mount(CompactionCard, { props: { content: malformed } })
    // Card still renders, but sections are empty
    expect(wrapper.find('[data-testid="compaction-card"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(0)
  })

  it('handles empty content (renders card, no entries, no summary)', () => {
    wrapper = mount(CompactionCard, { props: { content: '' } })
    expect(wrapper.find('[data-testid="compaction-card"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="compaction-summary"]').exists()).toBe(false)
  })

  it('uses singular "message compacted" when there is exactly one entry', () => {
    const oneEntry = `<compact_messages>
      <message_index>
        <entry><id>h1</id><role>user</role><preview>only one</preview></entry>
      </message_index>
    </compact_messages>`
    wrapper = mount(CompactionCard, { props: { content: oneEntry } })
    expect(wrapper.text()).toContain('1 message compacted')
    expect(wrapper.text()).not.toContain('1 messages compacted')
  })

  it('renders all entries inline when total ≤ MAX_ENTRIES_VISIBLE (50)', () => {
    // Regression for the truncation perception bug: previously MAX_ENTRIES_VISIBLE was 10, so a
    // 12-entry envelope hid 2 entries behind a "Show all" button. With MAX_ENTRIES_VISIBLE = 50, a
    // 12-entry envelope renders everything inline (no toggle needed).
    const entries = Array.from({ length: 12 }, (_, i) => `    <entry>
      <id>h_${i + 1}</id>
      <role>user</role>
      <preview>message ${i + 1}</preview>
    </entry>`).join('\n')
    const envelope = `<compact_messages>
      <metadata><original_count>12</original_count></metadata>
      <message_index>
${entries}
      </message_index>
    </compact_messages>`
    wrapper = mount(CompactionCard, { props: { content: envelope } })
    const renderedEntries = wrapper.findAll('[data-testid="compaction-entry"]')
    expect(renderedEntries).toHaveLength(12)
    // No "Show all" button when entries ≤ limit
    expect(wrapper.find('[data-testid="compaction-show-more"]').exists()).toBe(false)
  })

  it('still hides entries beyond MAX_ENTRIES_VISIBLE behind a toggle', () => {
    // Regression: a 60-entry envelope should still show 50 by default and expose a "Show all 60"
    // button for the remaining 10. The scrollable list (max-height 400px; overflow-y auto) handles
    // the visual cap; the toggle handles keyboard-only accessibility.
    const entries = Array.from({ length: 60 }, (_, i) => `    <entry>
      <id>h_${i + 1}</id>
      <role>user</role>
      <preview>message ${i + 1}</preview>
    </entry>`).join('\n')
    const envelope = `<compact_messages>
      <message_index>
${entries}
      </message_index>
    </compact_messages>`
    wrapper = mount(CompactionCard, { props: { content: envelope } })
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(50)
    const showMore = wrapper.find('[data-testid="compaction-show-more"]')
    expect(showMore.exists()).toBe(true)
    expect(showMore.text()).toContain('Show all 60')
  })
})
