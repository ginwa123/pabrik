/** Folder-mode diff, end to end in the panel. The contract this pins: the frontend reads diffs ONLY
 * through folder mode. `loadFullList` makes ONE POST for the whole repo and primes the shared
 * snapshot, so clicking a file row costs ZERO further requests. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache, readFolderDiff } from '../../../helpers/folderDiffCache'
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

const diffFor = (path: string) =>
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-old\n+new`

// What the server answers for `folder: ""` — the whole repo, staged side
// first for anything both-staged-and-modified. The client named a folder,
// not a file list.
const FOLDER_RESULT = {
  diffs: [
    { path: 'staged.txt', diff_content: diffFor('staged.txt'), staged: true },
    { path: 'dirty.txt', diff_content: diffFor('dirty.txt'), staged: false },
    { path: 'new.txt', diff_content: diffFor('new.txt'), staged: false },
  ],
}

const mountPanel = () =>
  mount(SidebarDiffPanel, {
    global: { plugins: [testRouter] },
    props: { cwd: '/repo' },
    attachTo: document.body,
  })

/** Click a file row in the panel's own list, the way a user does. */
const clickFileRow = async (wrapper: ReturnType<typeof mountPanel>, label: string) => {
  const row = wrapper
    .findAll('.diff-file-row, [data-testid="file-row"]')
    .find((r) => r.text().includes(label))
  // The rows carry no stable class in every build; fall back to the first
  // clickable element whose text names the file.
  const target =
    row ??
    wrapper.findAll('button').find((b) => b.text().includes(label)) ??
    wrapper.findAll('[role="button"]').find((b) => b.text().includes(label))
  expect(target).toBeTruthy()
  await (target as { trigger: (e: string) => Promise<unknown> }).trigger('click')
}

describe('SidebarDiffPanel folder diff', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // The snapshot is module-level on purpose (that is what makes a click
    // free), so it must be dropped between tests or one test's repo leaks
    // into the next.
    clearFolderDiffCache()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue(FOLDER_RESULT)
  })

  it('uses ONE folder call for the whole repo instead of N per-file fetches', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    // Whole repo, no file list — the server walks it.
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFolderDiffsMock).toHaveBeenCalledWith('/repo')
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{ path: string; lines: unknown[] }>
    expect(files.map((f) => f.path)).toEqual(['staged.txt', 'dirty.txt', 'new.txt'])
    expect(files.every((f) => f.lines.length > 0)).toBe(true)
  })

  it('primes the shared snapshot so a file click costs zero requests', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)

    // The snapshot is what a click reads. Prime-and-read is the contract the
    // click handler depends on, so assert it directly rather than only
    // inferring it from request counts.
    expect(readFolderDiff('/repo', 'dirty.txt', false)?.diff_content).toContain('+new')
    // Staged and unstaged are separate entries — same path, both sides.
    expect(readFolderDiff('/repo', 'staged.txt', true)?.diff_content).toContain('+new')
    expect(readFolderDiff('/repo', 'staged.txt', false)).toBeNull()

    const before = getGitFolderDiffsMock.mock.calls.length
    await clickFileRow(wrapper, 'dirty.txt')
    await flushPromises()
    expect(getGitFolderDiffsMock.mock.calls.length).toBe(before)
    expect(wrapper.emitted('show-diff')).toBeTruthy()
  })

  it('renders error rows when the folder call fails, and never retries per file', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    getGitFolderDiffsMock.mockRejectedValue(new Error('boom'))
    const wrapper = mountPanel()
    await flushPromises()

    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    // The failure must be visible, not silently swallowed into empty rows.
    expect(error).toHaveBeenCalled()
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{ path: string; error?: string }>
    // Every row is reported, marked failed — no file quietly disappears and
    // no second wave of per-file requests goes out.
    expect(files.map((f) => f.path)).toEqual(['staged.txt', 'dirty.txt', 'new.txt'])
    expect(files.every((f) => !!f.error)).toBe(true)
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    error.mockRestore()
  })

  it('scales: 60 changed files are still one request', async () => {
    const many = Array.from({ length: 60 }, (_, i) => ({
      index_status: ' ',
      worktree_status: 'M',
      path: `f${i}.txt`,
    }))
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: true,
      staged_files: [],
      modified_files: many,
      untracked_files: [],
    })
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: many.map((f) => ({ ...f, diff_content: diffFor(f.path), staged: false })),
    })
    const wrapper = mountPanel()
    await flushPromises()

    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    const listed = wrapper.emitted('show-diff-list')
    expect(listed![0]![0]).toHaveLength(60)
  })
})
