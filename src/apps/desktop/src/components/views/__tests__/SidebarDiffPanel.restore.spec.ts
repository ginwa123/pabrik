/**  * Refresh lands on chat: the panel never auto-selects from ?diff= on list load. A reload keeps the
 * param the scroll-spy wrote while the viewer was open; ChatView strips it on mount while the
 * center is closed. Row clicks still emit show-diff instantly as before. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { encodePathParam } from '../chat_right_sidebar/parseUnifiedDiff'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const { getGitChangesMock, getGitFolderDiffsMock, getPrStatusMock } =
  vi.hoisted(() => ({
    getGitChangesMock: vi.fn(),
    getGitFolderDiffsMock: vi.fn(),
    getPrStatusMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getPrDiff: vi.fn(),
    getPrStatus: getPrStatusMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [],
  modified_files: [
    { index_status: ' ', worktree_status: 'M', path: 'dirty.txt' },
    { index_status: ' ', worktree_status: 'M', path: 'other.txt' },
  ],
  untracked_files: [],
}

const diffFor = (path: string) =>
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-old\n+new`

async function mountWithDiff(diff: string | null) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  if (diff === null) await router.push('/')
  else await router.push({ path: '/', query: { diff } })
  await router.isReady()
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [router] },
    props: { cwd: '/repo' },
  })
  await flushPromises()
  return wrapper
}

describe('SidebarDiffPanel ?diff= is ignored on load', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [
        { path: 'dirty.txt', diff_content: diffFor('dirty.txt'), staged: false },
        { path: 'other.txt', diff_content: diffFor('other.txt'), staged: false },
      ],
    })
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      title: 'Test',
      pr_url: 'https://github.com/acme/app/pull/42',
      number: 42,
      mergeable: '',
      merge_state: '',
      head_ref: 'feature',
      base_ref: 'main',
      author: 'acme',
      created_at: '',
      updated_at: '',
      merged_at: '',
      closed_at: '',
      additions: 0,
      deletions: 0,
      changed_files: 2,
    })
  })

  it('does NOT auto-select even when ?diff= names a listed file', async () => {
    const wrapper = await mountWithDiff(encodePathParam('other.txt'))
    // Full list still emitted for the stacked center view...
    expect(wrapper.emitted('show-diff-list')).toHaveLength(1)
    // ...but no instant selection — refresh lands on chat.
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })

  it('ignores a param that matches no listed file', async () => {
    const wrapper = await mountWithDiff(encodePathParam('gone.txt'))
    expect(wrapper.emitted('show-diff-list')).toHaveLength(1)
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })

  it('ignores garbage params without breaking the list', async () => {
    const wrapper = await mountWithDiff('!!!not-a-path!!!')
    expect(wrapper.emitted('show-diff-list')).toHaveLength(1)
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })

  it('stays silent with no param (plain list load)', async () => {
    const wrapper = await mountWithDiff(null)
    expect(wrapper.emitted('show-diff-list')).toHaveLength(1)
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })
})
