import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

/** The PR panel redraw: the request header, the status chips and the
 *  Conversation tab. These lock the behaviour the redraw promised: the title
 *  is on the screen, and each chip opens the tab that holds its reason. */
const {
  getGitChangesMock,
  getGitFolderDiffsMock,
  getPrDiffMock,
  getPrStatusMock,
  getPrConversationMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
  getPrConversationMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
    getPrConversation: getPrConversationMock,
    getGitCommits: vi.fn(),
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const PR_STATUS = {
  provider: 'github',
  pr_url: 'https://github.com/acme/app/pull/42',
  number: 42,
  title: 'fix(url): the settings URL names the workspace',
  state: 'OPEN',
  status: 'open',
  mergeable: 'MERGEABLE',
  merge_state: 'UNSTABLE',
  head_sha: 'abc123',
  head_ref: 'worktree/fix-url',
  base_ref: 'main',
  author: 'gilang',
  created_at: '2026-10-20T19:26:21Z',
  updated_at: '',
  merged_at: '',
  closed_at: '',
  additions: 27,
  deletions: 3,
  changed_files: 2,
  review_decision: 'CHANGES_REQUESTED',
  checks: { total: 3, passed: 1, failed: 2, pending: 0, skipped: 0, cancelled: 0 },
}

const PR_DIFF = `diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1 +1 @@
-a
+b`

const mountPanel = async (props: Record<string, unknown> = {}) => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/' })
  await router.isReady()
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [router] },
    props: {
      cwd: '/repo',
      prUrl: 'https://github.com/acme/app/pull/42',
      prProvider: 'github',
      ...props,
    } as never,
  })
  await flushPromises()
  return { wrapper, router }
}

describe('SidebarDiffPanel — the request header and the status chips', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    getGitFolderDiffsMock.mockResolvedValue({ diffs: [] })
    getPrDiffMock.mockResolvedValue({
      diff_content: PR_DIFF,
      base: 'main',
      head: 'worktree/fix-url',
      truncated: false,
    })
    getPrStatusMock.mockResolvedValue(PR_STATUS)
    getPrConversationMock.mockResolvedValue({
      provider: 'github',
      number: 42,
      title: PR_STATUS.title,
      body: '## What\n\nThe panel shows the title now.',
      author: 'gilang',
      created_at: '2026-10-20T19:26:21Z',
      review_decision: 'CHANGES_REQUESTED',
      comments: [],
      reviews: [],
      comment_count: 0,
      detail: '',
    })
  })

  it("shows the request's title, its author and its refs", async () => {
    const { wrapper } = await mountPanel()
    expect(wrapper.get('[data-testid="sidebar-pr-title"]').text()).toBe(
      'fix(url): the settings URL names the workspace',
    )
    const refs = wrapper.get('[data-testid="sidebar-pr-refs"]').text()
    expect(refs).toContain('gilang')
    expect(refs).toContain('main')
    expect(refs).toContain('worktree/fix-url')
  })

  it('counts the failing checks in the chip', async () => {
    const { wrapper } = await mountPanel()
    expect(wrapper.get('[data-testid="sidebar-pr-chip-checks"]').text()).toContain(
      '2 checks failed',
    )
  })

  it('opens the checks tab when the failing-checks chip is pressed', async () => {
    const { wrapper } = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-chip-checks"]').trigger('click')
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-tab-checks"]').attributes('aria-selected')).toBe(
      'true',
    )
  })

  it('opens the conversation tab when the review chip is pressed', async () => {
    const { wrapper } = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-chip-review"]').trigger('click')
    await flushPromises()
    expect(
      wrapper.get('[data-testid="sidebar-tab-conversation"]').attributes('aria-selected'),
    ).toBe('true')
    expect(wrapper.find('[data-testid="pr-conversation-panel"]').exists()).toBe(true)
  })

  it('puts the conversation tab first, and only in change request mode', async () => {
    const { wrapper } = await mountPanel()
    const tabs = wrapper.findAll('[role="tab"]')
    expect(tabs[0]!.attributes('data-testid')).toBe('sidebar-tab-conversation')

    const noPr = await mountPanel({ prUrl: '', prProvider: '' })
    expect(noPr.wrapper.find('[data-testid="sidebar-tab-conversation"]').exists()).toBe(false)
  })

  it('names the failing checks in the merge box, not just a category', async () => {
    const { wrapper } = await mountPanel()
    expect(wrapper.get('[data-testid="pr-merge-headline"]').text()).toBe(
      '2 checks failed, changes requested',
    )
  })

  it('keeps saying the merge is blocked when the block is a review', async () => {
    getPrStatusMock.mockResolvedValue({
      ...PR_STATUS,
      merge_state: 'BLOCKED',
      review_decision: 'CHANGES_REQUESTED',
    })
    const { wrapper } = await mountPanel()
    // The headline still says the merge is blocked; the reason moves to the
    // line under it, where the counts belong.
    expect(wrapper.get('[data-testid="pr-merge-headline"]').text()).toBe('Merging is blocked')
    expect(wrapper.get('[data-testid="pr-merge-detail"]').text()).toContain('changes requested')
  })
})
