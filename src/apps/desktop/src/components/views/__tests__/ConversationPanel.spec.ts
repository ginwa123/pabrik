import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import ConversationPanel from '../chat_right_sidebar/ConversationPanel.vue'

/** The Conversation tab: the forge's own thread, read only. These lock the
 *  behaviour a reviewer depends on — the body, the comments, the verdicts,
 *  and the one rule that matters: a comment is text, never HTML. */
const { getPrConversationMock } = vi.hoisted(() => ({
  getPrConversationMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, getPrConversation: getPrConversationMock }
})

const CONVERSATION = {
  provider: 'github',
  number: 1010,
  title: 'fix(url): the settings URL names the workspace',
  body: '## What\n\nThe panel shows the title now.',
  author: 'gilang',
  created_at: '2026-10-20T19:26:21Z',
  review_decision: 'CHANGES_REQUESTED',
  comments: [
    {
      author: 'reviewer',
      body: 'One spec still assumes the old shape.',
      created_at: '2026-10-20T20:00:00Z',
      url: 'https://github.com/acme/app/pull/1010#issue-1',
    },
  ],
  reviews: [
    {
      author: 'reviewer',
      state: 'CHANGES_REQUESTED',
      body: 'Two specs still assume the old URL shape.',
      created_at: '2026-10-20T20:05:00Z',
      url: '',
    },
  ],
  comment_count: 2,
  detail: '',
}

const mountPanel = async (props: Record<string, unknown> = {}) => {
  const wrapper = mount(ConversationPanel, {
    props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/1010', ...props } as never,
  })
  await flushPromises()
  return wrapper
}

describe('ConversationPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getPrConversationMock.mockResolvedValue(CONVERSATION)
  })

  it('renders the request body as markdown', async () => {
    const wrapper = await mountPanel()
    const body = wrapper.get('[data-testid="conversation-body"]')
    // The body was written in markdown, so the heading is a heading.
    expect(body.find('h2').text()).toBe('What')
    expect(body.text()).toContain('The panel shows the title now.')
  })

  it('renders every comment with its author', async () => {
    const wrapper = await mountPanel()
    const comments = wrapper.findAll('[data-testid="conversation-comment"]')
    expect(comments).toHaveLength(1)
    expect(comments[0]!.text()).toContain('reviewer')
    expect(comments[0]!.text()).toContain('One spec still assumes the old shape.')
  })

  it('renders a review with its verdict', async () => {
    const wrapper = await mountPanel()
    const reviews = wrapper.findAll('[data-testid="conversation-review"]')
    expect(reviews).toHaveLength(1)
    expect(reviews[0]!.get('[data-testid="conversation-verdict"]').text()).toBe('Changes requested')
    expect(reviews[0]!.text()).toContain('Two specs still assume the old URL shape.')
  })

  it('puts the review decision at the top of the thread', async () => {
    const wrapper = await mountPanel()
    expect(wrapper.get('[data-testid="conversation-decision"]').text()).toBe('Changes requested')
  })

  it('never runs HTML the forge wrote', async () => {
    // A comment can be written by anyone who can comment on the repository.
    getPrConversationMock.mockResolvedValue({
      ...CONVERSATION,
      body: '<img src=x onerror="window.__pwned = true">',
    })
    const wrapper = await mountPanel()
    const body = wrapper.get('[data-testid="conversation-body"]')
    expect(body.find('img').exists()).toBe(false)
    expect(body.html()).toContain('&lt;img')
    expect((window as unknown as { __pwned?: boolean }).__pwned).toBeUndefined()
  })

  it("shows the server's own error instead of an empty thread", async () => {
    getPrConversationMock.mockRejectedValue(new Error('gh: authentication failed'))
    const wrapper = await mountPanel()
    expect(wrapper.get('[data-testid="conversation-error"]').text()).toContain(
      'gh: authentication failed',
    )
    expect(wrapper.find('[data-testid="conversation-thread"]').exists()).toBe(false)
  })

  it('says there is no conversation when no change request is attached', async () => {
    const wrapper = await mountPanel({ prUrl: '' })
    expect(wrapper.get('[data-testid="conversation-no-pr"]').text()).toContain('pull request')
    expect(getPrConversationMock).not.toHaveBeenCalled()
  })

  it('points at the forge as the place where the thread is written', async () => {
    const wrapper = await mountPanel()
    const link = wrapper.get('[data-testid="conversation-open-on-forge"]')
    expect(link.attributes('href')).toBe('https://github.com/acme/app/pull/1010')
    expect(link.text()).toContain('Open on GitHub')
  })

  it('reports the thread size so the tab can show a count', async () => {
    const wrapper = await mountPanel()
    expect(wrapper.emitted('loaded')).toEqual([[2]])
  })
})
