/** Per-file `+added / -removed` on the sidebar's file rows. The counts are derived from diff text
 * the panel ALREADY holds — the PR diff it parsed, and the folder-mode batch payload it fetched for
 * the center column. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

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
    getGitCommits: vi.fn().mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 0,
      commits: [],
    }),
    getGitCommitDetail: vi.fn().mockResolvedValue(null),
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

/** One file's chunk: 2 added, 1 removed. */
const diffFor = (path: string) =>
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1,2 @@\n-old\n+new\n+extra`

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [{ index_status: 'M', worktree_status: ' ', path: 'staged.txt' }],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [{ index_status: '??', worktree_status: '??', path: 'new.txt' }],
}

const PR_DIFF = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1 +1,2 @@
-old
+new
+extra
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index abc1234..0000000
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-bye
-later`

const mountPanel = async (props: Record<string, unknown> = {}) => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/' })
  await router.isReady()
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [router] },
    props: { cwd: '/repo', ...props } as never,
  })
  await flushPromises()
  return wrapper
}

/** The `+N / -N` text on one row, or '' when the chip is absent. */
const countsText = (wrapper: Awaited<ReturnType<typeof mountPanel>>, testId: string): string =>
  wrapper.find(`[data-testid="${testId}"] [data-testid="diff-counts"]`).exists()
    ? wrapper.find(`[data-testid="${testId}"] [data-testid="diff-counts"]`).text()
    : ''

describe('SidebarDiffPanel — per-file line counts', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockImplementation(async () => ({
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

  it('shows counts on every worktree row kind', async () => {
    const wrapper = await mountPanel()
    expect(countsText(wrapper, 'sidebar-diff-file-staged-staged.txt')).toBe('+2-1')
    expect(countsText(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe('+2-1')
    expect(countsText(wrapper, 'sidebar-diff-file-untracked-new.txt')).toBe('+2-1')
  })

  it('shows counts on PR rows, including a pure deletion', async () => {
    const wrapper = await mountPanel({ prUrl: 'https://github.com/acme/app/pull/42' })
    expect(countsText(wrapper, 'sidebar-pr-file-foo.txt')).toBe('+2-1')
    // A deleted file is all removals — the row must not read as "no change".
    expect(countsText(wrapper, 'sidebar-pr-file-gone.txt')).toBe('+0-2')
  })

  it('costs zero extra requests — the counts ride the payload already fetched', async () => {
    await mountPanel()
    // One status call + one folder-mode batch. No per-file diff request.
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
  })

  it('renders NOTHING when the diff fetch failed — never a lying +0 -0', async () => {
    // A backend outage must not turn every row into "unchanged".
    getGitFolderDiffsMock.mockRejectedValue(new Error('backend down'))
    const wrapper = await mountPanel()
    expect(wrapper.find('[data-testid="diff-counts"]').exists()).toBe(false)
    // The rows themselves still render — only the counts are unknown.
    expect(wrapper.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(true)
  })

  it('renders NOTHING for a file the batch payload did not cover', async () => {
    // The server only reports CHANGED paths, so a row can legitimately have
    // no diff entry. Unknown, not zero.
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: diffFor('dirty.txt'), staged: false }],
    })
    const wrapper = await mountPanel()
    expect(countsText(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe('+2-1')
    expect(countsText(wrapper, 'sidebar-diff-file-staged-staged.txt')).toBe('')
    expect(countsText(wrapper, 'sidebar-diff-file-untracked-new.txt')).toBe('')
  })

  it('keeps the status chip the first direct-child span of the row', async () => {
    // SidebarDiffPanel.chrome.spec.ts selects `[data-testid=…] > span` to
    // read the status letter. The counts must not become that first span.
    const wrapper = await mountPanel()
    const row = wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
    const firstSpan = Array.from(row.element.children).find((el) => el.tagName === 'SPAN')
    expect(firstSpan?.textContent).toBe('M')
  })
})
