/**
 * Surgical stage/unstage — the `+` / `−` buttons must NOT re-fetch the
 * git-status list.
 *
 * Before this, `stageFile` / `unstageFile` answered with
 * `await loadGitStatus()` — a full `git status --porcelain -uall` plus
 * untracked-directory expansion, then a second folder-wide diff request. On a
 * 40-file worktree that is two git spawns and a re-render of every row, for a
 * change that moved exactly one path between two lists. The list visibly
 * blanks and repopulates.
 *
 * Now the backend emits `git_file_staged` / `git_file_unstaged` on the
 * central `git_file_stage` routing key (see
 * src/agentic_loop/git_file_stage_events.zig) and the panel moves ONE row.
 *
 * What this spec pins:
 *   1. clicking `+` / `−` issues ZERO `getGitChanges` calls — the row moves
 *      locally, so the list never blinks;
 *   2. the row lands in the right list (Changes → Staged, Untracked →
 *      Staged, Staged → Changes);
 *   3. an SSE event for a DIFFERENT cwd is ignored — one tab can show
 *      several worktrees;
 *   4. a `failed` event moves nothing;
 *   5. the manual ↻ refresh and the commit flow KEEP the full reload path.
 */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'
import { installSseBus, __resetSseBus, __dispatchSseBus } from '../../../helpers/sseBus'
import type { GitFileStageEvent } from '../../../api'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const {
  getGitChangesMock,
  getGitFolderDiffsMock,
  getGitFileDiffsMock,
  stageGitFilesMock,
  unstageGitFilesMock,
  commitGitChangesMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
  getGitFileDiffsMock: vi.fn(),
  stageGitFilesMock: vi.fn(),
  unstageGitFilesMock: vi.fn(),
  commitGitChangesMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getGitFileDiffs: getGitFileDiffsMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: unstageGitFilesMock,
    commitGitChanges: commitGitChangesMock,
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
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1,2 @@\n-old\n+new\n+extra`

/** The `+` button on a row in the Changes list. */
const plusButton = (wrapper: ReturnType<typeof mount>, path: string) =>
  wrapper.get(`[data-testid="sidebar-diff-file-unstaged-${path}"] button`)

/** The `+` button on a row in the Untracked list (its own testid prefix). */
const plusButtonUntracked = (wrapper: ReturnType<typeof mount>, path: string) =>
  wrapper.get(`[data-testid="sidebar-diff-file-untracked-${path}"] button`)

/** The `−` button on a row in the Staged list. */
const minusButton = (wrapper: ReturnType<typeof mount>, path: string) =>
  wrapper.get(`[data-testid="sidebar-diff-file-staged-${path}"] button`)

const rowExists = (wrapper: ReturnType<typeof mount>, testId: string) =>
  wrapper.find(`[data-testid="${testId}"]`).exists()

/** The section headers ("Staged Changes (2)", "Changes (1)", "Untracked (1)")
 * as plain strings. Queried by their own class rather than by
 * `wrapper.text()`, because "Staged Changes (2)" CONTAINS "Changes (" — a
 * substring assertion cannot tell an emptied Changes section from a Staged
 * one that happens to be non-empty. */
const sectionHeaders = (wrapper: ReturnType<typeof mount>): string[] =>
  wrapper
    .findAll('.text-micro.font-semibold.uppercase')
    .map((el) => el.text().trim())
    .filter((t) => /^(Staged Changes|Changes|Untracked) \(\d+\)$/.test(t))

describe('SidebarDiffPanel surgical stage/unstage', () => {
  beforeEach(async () => {
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
    // LIST-mode re-prime: one request for one path.
    getGitFileDiffsMock.mockImplementation(
      async (_cwd: string, files: { file: string; staged: boolean }[]) => ({
        diffs: files.map((f) => ({
          path: f.file,
          diff_content: diffFor(f.file),
          staged: f.staged,
        })),
      }),
    )
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
    commitGitChangesMock.mockResolvedValue({
      success: true,
      message: 'ok',
      commit_sha: 'abc123def456abc123def456abc123def456abc12',
    })
    // The panel subscribes in onMounted; `installSseBus` with tab sharing off
    // opens no EventSource, so no network happens in the test.
    installSseBus(undefined, { tabSharing: 'off' })
  })

  afterEach(() => {
    __resetSseBus()
  })

  const mountPanel = () =>
    mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })

  it('clicking + moves the row to Staged WITHOUT re-fetching git status', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    // One load on mount.
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-dirty.txt')).toBe(false)

    await plusButton(wrapper, 'dirty.txt').trigger('click')
    await flushPromises()

    // THE POINT OF THE CHANGE: no second git-status fetch.
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(stageGitFilesMock).toHaveBeenCalledWith('/repo', ['dirty.txt'])
    // The row moved.
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-dirty.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe(false)
    // …and the section header count followed it. An emptied section is
    // hidden outright rather than rendered as "(0)".
    expect(sectionHeaders(wrapper)).toEqual(['Staged Changes (2)', 'Untracked (1)'])
  })

  it('clicking − moves the row back to Changes WITHOUT re-fetching git status', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    await minusButton(wrapper, 'staged.txt').trigger('click')
    await flushPromises()

    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(unstageGitFilesMock).toHaveBeenCalledWith('/repo', ['staged.txt'])
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-staged.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-staged.txt')).toBe(false)
  })

  it('staging an untracked file moves it out of Untracked into Staged', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    await plusButtonUntracked(wrapper, 'new.txt').trigger('click')
    await flushPromises()

    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-new.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-untracked-new.txt')).toBe(false)
    expect(sectionHeaders(wrapper)).toEqual(['Staged Changes (2)', 'Changes (1)'])
  })

  it('an SSE event for a different cwd is ignored', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    __dispatchSseBus('gitFileStage', {
      action: 'staged',
      path: 'dirty.txt',
      cwd: '/some/other/worktree',
      failed: false,
    } satisfies GitFileStageEvent)
    await flushPromises()

    // Nothing moved — the panel is bound to /repo.
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-dirty.txt')).toBe(false)
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
  })

  it('a failed stage event moves nothing', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    __dispatchSseBus('gitFileStage', {
      action: 'staged',
      path: 'dirty.txt',
      cwd: '/repo',
      failed: true,
    } satisfies GitFileStageEvent)
    await flushPromises()

    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-dirty.txt')).toBe(false)
  })

  it('an SSE event from ANOTHER tab staging the same file still moves the row', async () => {
    // The channel is central: any client that staged a file in THIS cwd must
    // update every panel bound to it, not just the one that clicked.
    const wrapper = mountPanel()
    await flushPromises()

    __dispatchSseBus('gitFileStage', {
      action: 'staged',
      path: 'dirty.txt',
      cwd: '/repo',
      failed: false,
    } satisfies GitFileStageEvent)
    await flushPromises()

    expect(rowExists(wrapper, 'sidebar-diff-file-staged-dirty.txt')).toBe(true)
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
  })

  it('re-primes only the moved file diff, not the whole folder', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    getGitFileDiffsMock.mockClear()
    getGitFolderDiffsMock.mockClear()

    await plusButton(wrapper, 'dirty.txt').trigger('click')
    await flushPromises()

    // One LIST-mode request for one path — never the folder-wide re-fetch.
    expect(getGitFileDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFileDiffsMock).toHaveBeenCalledWith('/repo', [{ file: 'dirty.txt', staged: true }])
    expect(getGitFolderDiffsMock).not.toHaveBeenCalled()
  })

  it('a path staged AND further modified: + on the Changes row moves that row', async () => {
    // index M + worktree M — the backend reports the path in BOTH lists. The
    // `from` list must come from the ACTION (the `+` only ever sits on a
    // Changes row), not from list precedence: precedence would see it in
    // Staged, compute to === from, and leave the clicked row sitting there
    // while the POST reported success.
    getGitChangesMock.mockResolvedValue({
      ...CHANGES,
      staged_files: [{ index_status: 'M', worktree_status: 'M', path: 'both.txt' }],
      modified_files: [{ index_status: 'M', worktree_status: 'M', path: 'both.txt' }],
      untracked_files: [],
    })
    const wrapper = mountPanel()
    await flushPromises()
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-both.txt')).toBe(true)
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-both.txt')).toBe(true)

    await plusButton(wrapper, 'both.txt').trigger('click')
    await flushPromises()

    // `git add` folded the worktree change into the index: the Changes row is
    // genuinely gone, and exactly one Staged row survives (no duplicate).
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-both.txt')).toBe(false)
    expect(wrapper.findAll('[data-testid="sidebar-diff-file-staged-both.txt"]')).toHaveLength(1)
  })

  it('a path staged AND further modified: − keeps the Changes row', async () => {
    getGitChangesMock.mockResolvedValue({
      ...CHANGES,
      staged_files: [{ index_status: 'M', worktree_status: 'M', path: 'both.txt' }],
      modified_files: [{ index_status: 'M', worktree_status: 'M', path: 'both.txt' }],
      untracked_files: [],
    })
    const wrapper = mountPanel()
    await flushPromises()

    await minusButton(wrapper, 'both.txt').trigger('click')
    await flushPromises()

    // `git restore --staged` reverts the index only, so the worktree change
    // is still there — the Changes row must survive, exactly once.
    expect(rowExists(wrapper, 'sidebar-diff-file-staged-both.txt')).toBe(false)
    expect(wrapper.findAll('[data-testid="sidebar-diff-file-unstaged-both.txt"]')).toHaveLength(1)
  })

  it('a duplicate delivery (POST fallback + SSE event) moves the row once', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    await plusButton(wrapper, 'dirty.txt').trigger('click')
    await flushPromises()
    // The bus also delivered the same event; the second application must be a
    // no-op rather than appending a second Staged row for the same path.
    __dispatchSseBus('gitFileStage', {
      action: 'staged',
      path: 'dirty.txt',
      cwd: '/repo',
      failed: false,
    } satisfies GitFileStageEvent)
    await flushPromises()

    expect(wrapper.findAll('[data-testid="sidebar-diff-file-staged-dirty.txt"]')).toHaveLength(1)
    expect(rowExists(wrapper, 'sidebar-diff-file-unstaged-dirty.txt')).toBe(false)
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
  })

  it('the manual ↻ refresh still reloads the whole list', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    await wrapper.get('[data-testid="sidebar-diff-refresh"]').trigger('click')
    await flushPromises()

    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
  })

  it('the commit flow still reloads the whole list', async () => {
    const wrapper = mountPanel()
    await flushPromises()

    await wrapper.get('[data-testid="sidebar-commit-message"]').setValue('fix: things')
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-commit-button"]').trigger('click')
    await flushPromises()

    expect(commitGitChangesMock).toHaveBeenCalledWith('/repo', 'fix: things')
    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
  })
})
