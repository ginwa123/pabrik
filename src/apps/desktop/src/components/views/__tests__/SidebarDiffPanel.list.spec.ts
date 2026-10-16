/** Phase 3 center lazy diff (3.1): the panel emits the FULL ordered file list (`show-diff-list
 * {files: DiffSelection[]}`) in addition to the instant per-click `show-diff`. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'
import { createRouter, createMemoryHistory } from 'vue-router'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const { getGitChangesMock, getGitFolderDiffsMock, getPrDiffMock, getPrStatusMock } = vi.hoisted(
  () => ({
    getGitChangesMock: vi.fn(),
    getGitFolderDiffsMock: vi.fn(),
    getPrDiffMock: vi.fn(),
    getPrStatusMock: vi.fn(),
  }),
)

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const PR_DIFF = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1 +1 @@
-old
+new
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello`

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [{ index_status: 'M', worktree_status: ' ', path: 'staged.txt' }],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [{ index_status: '??', worktree_status: '??', path: 'new.txt' }],
}

const diffFor = (path: string) =>
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-old\n+new`

describe('SidebarDiffPanel show-diff-list (3.1)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // The snapshot is module-level (that is what makes a click free), so it
    // has to be dropped between tests or one repo leaks into the next.
    clearFolderDiffCache()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockImplementation(async (_cwd: string) => ({
      diffs: [
        { path: 'staged.txt', diff_content: diffFor('staged.txt'), staged: true },
        { path: 'dirty.txt', diff_content: diffFor('dirty.txt'), staged: false },
        { path: 'new.txt', diff_content: diffFor('new.txt'), staged: false },
      ],
    }))
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/42',
      base: 'main',
      head: 'feature',
      diff_content: PR_DIFF,
      truncated: false,
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

  it('PR mode emits the full parsed list without per-file fetches', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(getPrDiffMock).toHaveBeenCalledTimes(1)
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{
      path: string
      staged: boolean
      lines: unknown[]
      added: number
      removed: number
    }>
    expect(files).toHaveLength(2)
    expect(files.map((f) => f.path)).toEqual(['foo.txt', 'new.txt'])
    for (const f of files) {
      expect(f.staged).toBe(false)
      expect(f.lines.length).toBeGreaterThan(0)
    }
    expect(files[0]).toMatchObject({ added: 1, removed: 1 })
    expect(files[1]).toMatchObject({ added: 1, removed: 0 })
    // List load is silent: no instant show-diff until a row is clicked.
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })

  it('worktree mode fetches the whole repo in ONE folder call and emits the ordered list', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    // One request for every changed file — the per-file endpoint is gone from
    // this path entirely.
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFolderDiffsMock).toHaveBeenCalledWith('/repo')
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{ path: string; staged: boolean; lines: unknown[] }>
    expect(files.map((f) => f.path)).toEqual(['staged.txt', 'dirty.txt', 'new.txt'])
    expect(files[0]).toMatchObject({ staged: true })
    expect(files[1]).toMatchObject({ staged: false })
    for (const f of files) expect(f.lines.length).toBeGreaterThan(0)
    expect(wrapper.emitted('show-diff')).toBeUndefined()
  })

  it('a failed folder fetch marks every row, without a per-file retry wave', async () => {
    const errorLog = vi.spyOn(console, 'error').mockImplementation(() => {})
    getGitFolderDiffsMock.mockRejectedValue(new Error('nope'))
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{
      path: string
      lines: unknown[]
      added: number
      removed: number
      error?: string | null
    }>
    expect(files).toHaveLength(3)
    // Every row is reported and marked failed — nothing silently vanishes.
    expect(files.every((f) => f.lines.length === 0)).toBe(true)
    expect(files.every((f) => typeof f.error === 'string')).toBe(true)
    // The failure is visible, and the panel does NOT retry per file: that
    // retry path is what turned one error into a session of requests.
    expect(errorLog).toHaveBeenCalled()
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    errorLog.mockRestore()
  })

  it('shell re-emits both show-diff and show-diff-list', () => {
    const shellSrc = readFileSync(
      resolve(__dirname, '../chat_right_sidebar/ChatRightSidebar.vue'),
      'utf8',
    )
    expect(shellSrc).toMatch(/'show-diff-list'/)
    expect(shellSrc).toMatch(/show-diff-list.*emit\('show-diff-list'/)
  })
})
