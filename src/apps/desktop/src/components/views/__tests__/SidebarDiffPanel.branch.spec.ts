/** Branch source-of-truth: the bottom status bar (ChatView `gitStatus`) owns the branch;
 * SidebarDiffPanel only displays the drilled `branch` prop and keeps its own fetch as fallback. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const { getGitChangesMock, getGitFolderDiffsMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: false,
  staged_files: [],
  modified_files: [],
  untracked_files: [],
}

describe('SidebarDiffPanel branch source of truth', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({ diffs: [] })
  })

  it('prefers the drilled branch prop over the fetched branch', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', branch: 'worktree/my-feature' },
    })
    await flushPromises()
    const label = wrapper.get('[data-testid="sidebar-diff-branch"]')
    expect(label.text()).toContain('worktree/my-feature')
    expect(label.text()).not.toContain('main')
  })

  it('falls back to the fetched branch when no prop is given', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-diff-branch"]').text()).toContain('main')
  })

  it('ignores a stale fetch that resolves after a cwd switch', async () => {
    let resolveFirst!: (v: typeof CHANGES) => void
    const first = new Promise<typeof CHANGES>((r) => (resolveFirst = r))
    getGitChangesMock.mockReturnValueOnce(first)
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo-a' },
    })
    // Switch cwd before the first fetch resolves; second fetch is fast.
    getGitChangesMock.mockResolvedValue({ ...CHANGES, branch: 'worktree/b' })
    await wrapper.setProps({ cwd: '/repo-b' })
    resolveFirst({ ...CHANGES, branch: 'stale-a' })
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-diff-branch"]').text()).toContain('worktree/b')
  })
})
