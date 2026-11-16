import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const {
  getGitChangesMock,
  getGitFolderDiffsMock,
  stageGitFilesMock,
  unstageGitFilesMock,
} =
  vi.hoisted(() => ({
    getGitChangesMock: vi.fn(),
    getGitFolderDiffsMock: vi.fn(),
    stageGitFilesMock: vi.fn(),
    unstageGitFilesMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: unstageGitFilesMock,
  }
})

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [{ index_status: 'M', worktree_status: ' ', path: 'staged.txt' }],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [{ index_status: '??', worktree_status: '??', path: 'new.txt' }],
}

const DIFF = `diff --git a/dirty.txt b/dirty.txt
--- a/dirty.txt
+++ b/dirty.txt
@@ -1,2 +1,2 @@
 keep
-old
+new`

describe('SidebarDiffPanel', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
    stageGitFilesMock.mockResolvedValue({
      success: true,
      message: '',
      staged_files: [],
      failed_files: [],
    })
    unstageGitFilesMock.mockResolvedValue({
      success: true,
      message: '',
      staged_files: [],
      failed_files: [],
    })
  })

  it('renders file groups with counts', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    expect(wrapper.text()).toContain('Staged Changes (1)')
    expect(wrapper.text()).toContain('Changes (1)')
    expect(wrapper.text()).toContain('Untracked (1)')
    expect(wrapper.get('[data-testid="sidebar-diff-count"]').text()).toBe('3')
  })

  it('emits show-diff with parsed lines on file click (center renders)', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    // The mount already fetched the whole repo and primed the shared snapshot, so the click is a map read — no request at all.
    const before = getGitFolderDiffsMock.mock.calls.length
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(getGitFolderDiffsMock.mock.calls.length).toBe(before)
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'dirty.txt', staged: false, added: 1, removed: 1 })
    expect((emitted![0]![0] as { lines: unknown[] }).lines.length).toBeGreaterThan(0)
    // Panel is list-only: no inline diff section rendered.
    expect(wrapper.find('[data-testid="sidebar-diff-selected"]').exists()).toBe(false)
  })

  it('emits show-diff with error on diff fetch failure', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    // Mount primes the snapshot from its own folder fetch.
    clearFolderDiffCache()
    getGitFolderDiffsMock.mockRejectedValueOnce(new Error('nope'))
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'dirty.txt', error: 'Failed to load file diff' })
  })

  it('shows retry on list failure', async () => {
    getGitChangesMock.mockRejectedValueOnce(new Error('boom'))
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-diff-retry"]').exists()).toBe(true)
  })

  it('emits refresh on ↻ click so ChatView re-syncs the worktree binding', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-refresh"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('refresh')).toHaveLength(1)
  })

  it('stages a file and reloads', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    const row = wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
    await row.get('button[title="Stage file"]').trigger('click')
    await flushPromises()
    expect(stageGitFilesMock).toHaveBeenCalledWith('/repo', ['dirty.txt'])
  })
})
