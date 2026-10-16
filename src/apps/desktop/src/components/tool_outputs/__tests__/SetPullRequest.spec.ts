/** Behaviour of SetPullRequest.vue — the registered output card for the `set_pull_request` tool. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import SetPullRequest from '../SetPullRequest.vue'

const ATTACH_DATA = {
  session_id: 'task_1791883461055_3',
  attached: true,
  url: 'https://github.com/ginwa123/pabrik/pull/922',
  provider: 'github',
  number: '922',
  verified: true,
  warning: null,
  base: null,
  head: null,
}

const ATTACH_ENVELOPE = JSON.stringify({
  tool: 'set_pull_request',
  parameters: { pr_url: ATTACH_DATA.url },
  success: true,
  data: ATTACH_DATA,
  error: null,
  v: 1,
})

const CLEAR_DATA = { session_id: 'task_1791883461055_3', cleared: true }

const ERROR_ENVELOPE = JSON.stringify({
  tool: 'set_pull_request',
  parameters: { pr_url: 'https://github.com/ginwa123/pabrik/pull/631' },
  success: false,
  data: null,
  error: 'PR verification failed: not found',
  v: 1,
})

const GITLAB_DATA = {
  session_id: 'task_9',
  attached: true,
  url: 'https://gitlab.com/group/sub/repo/-/merge_requests/7',
  provider: 'gitlab',
  number: '7',
  verified: true,
  warning: null,
  base: null,
  head: null,
}

describe('SetPullRequest', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  const mountCard = (props: { content: unknown; expanded?: boolean; parameters?: string }) => {
    wrapper = mount(SetPullRequest, { props })
    return wrapper
  }

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('shows the change-request number in the header, never the payload', () => {
    const w = mountCard({ content: ATTACH_DATA })
    expect(w.text()).toContain('set_pull_request')
    expect(w.text()).toContain('#922')
    // The regression this card fixes: no raw envelope JSON in the transcript.
    expect(w.text()).not.toContain('session_id')
    expect(w.text()).not.toContain('{')
  })

  it('accepts the full envelope string too (the failure path threaded by ChatView)', () => {
    const w = mountCard({ content: ATTACH_ENVELOPE, expanded: true })
    expect(w.text()).toContain('#922')
    expect(w.find('[data-testid="set-pull-request-verified"]').text()).toContain('yes')
    expect(w.find('[data-testid="set-pull-request-url"]').attributes('href')).toBe(ATTACH_DATA.url)
  })

  it('marks the attach as succeeded', () => {
    const w = mountCard({ content: ATTACH_DATA })
    expect(w.text()).toContain('✓')
    expect(w.text()).not.toContain('✗')
  })

  it('reports the provider as right-meta so the forge is visible collapsed', () => {
    expect(mountCard({ content: ATTACH_DATA }).text()).toContain('github')
  })

  it('expands to a real link to the change request', async () => {
    const w = mountCard({ content: ATTACH_DATA, expanded: false })
    expect(w.find('[data-testid="set-pull-request-url"]').exists()).toBe(false)

    await w.find('[role="button"]').trigger('click')

    const link = w.find('[data-testid="set-pull-request-url"]')
    expect(link.exists()).toBe(true)
    expect(link.attributes('href')).toBe(ATTACH_DATA.url)
    expect(link.attributes('target')).toBe('_blank')
    expect(link.attributes('rel')).toBe('noopener noreferrer')
  })

  it("names the forge in the forge's own words (merge request on GitLab)", () => {
    const w = mountCard({ content: GITLAB_DATA, expanded: true })
    expect(w.text()).toContain('Merge request:')
    expect(w.text()).not.toContain('Pull request:')
  })

  it('says "(cleared)" and hides the verification row after an unbind', async () => {
    const w = mountCard({ content: CLEAR_DATA, expanded: true })
    expect(w.text()).toContain('(cleared)')
    expect(w.find('[data-testid="set-pull-request-verified"]').exists()).toBe(false)
    expect(w.text()).toContain('binding removed from this session')
  })

  it('renders the error message and a ✗ for a failed attach', () => {
    const w = mountCard({ content: ERROR_ENVELOPE, expanded: true })
    expect(w.text()).toContain('✗')
    expect(w.text()).toContain('PR verification failed: not found')
    expect(w.text()).toContain('error')
  })

  it('flags a bind that went through without a forge-CLI check', () => {
    const w = mountCard({
      content: { ...ATTACH_DATA, verified: false, warning: 'gh not found' },
      expanded: true,
    })
    expect(w.find('[data-testid="set-pull-request-verified"]').text()).toContain('no')
    expect(w.find('[data-testid="set-pull-request-warning"]').text()).toBe('gh not found')
  })

  it('shows the running badge while the result has not landed', () => {
    const w = mountCard({ content: '' })
    expect(w.find('[data-testid="tool-card-running"]').exists()).toBe(true)
  })

  it('threads the tool-call parameters through to the expanded body', () => {
    const w = mountCard({
      content: ATTACH_DATA,
      expanded: true,
      parameters: JSON.stringify({ pr_url: ATTACH_DATA.url }),
    })
    expect(w.html()).toContain('pr_url')
  })
})
