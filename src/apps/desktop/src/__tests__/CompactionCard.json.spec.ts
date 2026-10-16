/** CompactionCard, JSON envelopes: the task plan and the working directory the backend writes.
 * The XML envelopes from before the format change are covered by CompactionCard.spec.ts. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import CompactionCard from '../components/preview/CompactionCard.vue'

const envelope = (payload: Record<string, unknown>): string =>
  JSON.stringify({ compact_messages: { format_version: 2, ...payload } })

const METADATA = {
  session_id: 'sess_json_1',
  model: 'MiniMax-M3',
  compacted_at: '2026-10-16 12:00:00',
  original_count: 12,
}

const ENTRIES = [
  { id: 'adhoc_0', role: 'user', preview: 'fix the login bug', tool_call_id: null },
  { id: 'adhoc_1', role: 'tool', preview: 'tests pass: 42/42', tool_call_id: 'tc_7' },
]

describe('CompactionCard, JSON envelopes', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the task plan and its updated-at stamp', () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          plan: { markdown: '# Goal\n- [x] recon\n- [ ] ship', updated_at: '2026-10-16 11:59:00' },
          message_index: ENTRIES,
        }),
      },
    })

    const plan = wrapper.find('[data-testid="compaction-plan"]')
    expect(plan.exists()).toBe(true)
    expect(plan.text()).toContain('Task plan carried forward')
    expect(plan.text()).toContain('2026-10-16 11:59:00')
    expect(wrapper.find('[data-testid="compaction-plan-content"]').text()).toContain('- [ ] ship')
  })

  it('names the session cwd and the bound worktree as separate paths', () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          working_directory: {
            active_dir: '/repo/.worktrees/fix-login',
            session_cwd: '/repo',
            git_worktree_cwd: '/repo/.worktrees/fix-login',
            branch: 'worktree/fix-login',
            head: 'abc1234',
            is_git_repo: true,
            dirty_total: 2,
          },
          message_index: ENTRIES,
        }),
      },
    })

    const dir = wrapper.find('[data-testid="compaction-workdir"]')
    expect(dir.exists()).toBe(true)
    expect(wrapper.find('[data-testid="compaction-workdir-session"]').text()).toBe('/repo')
    expect(wrapper.find('[data-testid="compaction-workdir-worktree"]').text()).toBe(
      '/repo/.worktrees/fix-login',
    )
    expect(wrapper.find('[data-testid="compaction-workdir-active"]').text()).toBe(
      '/repo/.worktrees/fix-login',
    )
    expect(dir.text()).toContain('worktree/fix-login')
    expect(dir.text()).toContain('2 uncommitted files')
  })

  it('reports one uncommitted file in the singular', () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          working_directory: { session_cwd: '/repo', dirty_total: 1, is_git_repo: true },
          message_index: ENTRIES,
        }),
      },
    })

    expect(wrapper.find('[data-testid="compaction-workdir"]').text()).toContain(
      '1 uncommitted file',
    )
  })

  it('omits the changes line for a clean tree', () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          working_directory: { session_cwd: '/repo', dirty_total: 0, is_git_repo: true },
          message_index: ENTRIES,
        }),
      },
    })

    expect(wrapper.find('[data-testid="compaction-workdir"]').text()).not.toContain('uncommitted')
  })

  it('lists the dropped messages with their roles and previews', () => {
    wrapper = mount(CompactionCard, {
      props: { content: envelope({ metadata: METADATA, message_index: ENTRIES }) },
    })

    const rows = wrapper.findAll('[data-testid="compaction-entry"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]?.classes()).toContain('entry-role-user')
    expect(rows[0]?.text()).toContain('fix the login bug')
    expect(rows[1]?.classes()).toContain('entry-role-tool')
    expect(rows[1]?.text()).toContain('tc_7')
    expect(wrapper.text()).toContain('2 messages compacted')
  })

  it('shows no plan section and no working-directory section when the envelope carries neither', () => {
    wrapper = mount(CompactionCard, {
      props: { content: envelope({ metadata: METADATA, message_index: ENTRIES }) },
    })

    expect(wrapper.find('[data-testid="compaction-plan"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="compaction-workdir"]').exists()).toBe(false)
  })

  it('shows no summary section when the envelope was built without a summarization pass', () => {
    wrapper = mount(CompactionCard, {
      props: { content: envelope({ metadata: METADATA, summary: null, message_index: ENTRIES }) },
    })

    expect(wrapper.find('[data-testid="compaction-summary"]').exists()).toBe(false)
  })

  it('reveals the summary on click when one was written', async () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          summary: 'NEXT ACTION: merge the PR',
          message_index: ENTRIES,
        }),
      },
    })

    expect(wrapper.find('[data-testid="compaction-summary-content"]').exists()).toBe(false)
    await wrapper.find('[data-testid="compaction-summary-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="compaction-summary-content"]').text()).toContain(
      'NEXT ACTION: merge the PR',
    )
  })

  it('says how many older messages were rolled up but not listed', () => {
    wrapper = mount(CompactionCard, {
      props: {
        content: envelope({
          metadata: METADATA,
          message_index: ENTRIES,
          truncated_entries: { count: 63, note: 'older entries omitted' },
        }),
      },
    })

    expect(wrapper.find('[data-testid="compaction-omitted"]').text()).toContain('63 older messages')
  })

  it('stays silent about rolled-up messages when the index holds them all', () => {
    wrapper = mount(CompactionCard, {
      props: { content: envelope({ metadata: METADATA, message_index: ENTRIES }) },
    })

    expect(wrapper.find('[data-testid="compaction-omitted"]').exists()).toBe(false)
  })

  it('renders an empty card rather than crashing on a truncated JSON envelope', () => {
    wrapper = mount(CompactionCard, {
      props: { content: '{"compact_messages":{"metadata":{"session_id":"s1"' },
    })

    expect(wrapper.find('[data-testid="compaction-card"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(0)
  })

  it('renders an empty card for a JSON document that is not a compaction envelope', () => {
    wrapper = mount(CompactionCard, {
      props: { content: '{"some_other_payload":{"kind":"tool_result"}}' },
    })

    expect(wrapper.find('[data-testid="compaction-card"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="compaction-entry"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="compaction-plan"]').exists()).toBe(false)
  })

  it('keeps an empty-string summary from rendering an empty summary section', () => {
    wrapper = mount(CompactionCard, {
      props: { content: envelope({ metadata: METADATA, summary: '', message_index: ENTRIES }) },
    })

    expect(wrapper.find('[data-testid="compaction-summary"]').exists()).toBe(false)
  })
})
