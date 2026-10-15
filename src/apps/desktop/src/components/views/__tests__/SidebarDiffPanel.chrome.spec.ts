import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

/** The chrome redesign (docs/plans/2026-10-04-right-sidebar-redesign.md). These lock the NEW
 * behaviour the redesign introduced. */
/** Everything the old panel already guaranteed stays guaranteed by the existing specs —
 * `SidebarDiffPanel.tabs.spec.ts` owns the tab style contract, `pr.spec.ts` / `prConflict.spec.ts`
 * own the exact PR strings, and `ChatView.worktreeSidebar.spec.ts` owns the source greps. */
/** This file only covers what did not exist before: the letter chip, the dim/bright path split, the
 * filter, and the one-word tab labels. */

const { getGitChangesMock, getGitFolderDiffsMock, getPrDiffMock, getPrStatusMock, getGitCommitsMock } =
  vi.hoisted(() => ({
    getGitChangesMock: vi.fn(),
    getGitFolderDiffsMock: vi.fn(),
    getPrDiffMock: vi.fn(),
    getPrStatusMock: vi.fn(),
    getGitCommitsMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
    getGitCommits: getGitCommitsMock,
    getGitCommitDetail: vi.fn().mockResolvedValue(null),
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const PR_DIFF = Array.from(
  { length: 12 },
  (_, i) =>
    `diff --git a/dir/file${i}.txt b/dir/file${i}.txt\n--- a/dir/file${i}.txt\n+++ b/dir/file${i}.txt\n@@ -1 +1 @@\n-a\n+b`,
).join('\n')

const BASE_CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [],
  modified_files: [
    { index_status: ' ', worktree_status: 'M', path: 'src/a/b/modified.vue' },
    { index_status: ' ', worktree_status: 'A', path: 'src/a/b/added.vue' },
    { index_status: ' ', worktree_status: 'D', path: 'src/a/b/deleted.vue' },
  ],
  untracked_files: [{ index_status: '??', worktree_status: ' ', path: 'loose/untracked.ts' }],
}

const mountPanel = async (
  props: Record<string, unknown> = {},
  query: Record<string, string> = {},
) => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/', query })
  await router.isReady()
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [router] },
    props: { cwd: '/repo', ...props } as never,
  })
  await flushPromises()
  return { wrapper, router }
}

describe('SidebarDiffPanel chrome — status letter chips', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(BASE_CHANGES)
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 0,
      commits: [],
    })
  })

  it('renders one letter per git status, never a colour emoji', async () => {
    // Six emoji render at six different pixel sizes next to 12px paths and
    // cannot be asserted on. AGENTS.md: "No Emoji as Icons".
    const { wrapper } = await mountPanel()
    const letterOf = (path: string) =>
      wrapper.get(`[data-testid="sidebar-diff-file-unstaged-${path}"] > span`).text()

    expect(letterOf('src/a/b/modified.vue')).toBe('M')
    expect(letterOf('src/a/b/added.vue')).toBe('A')
    expect(letterOf('src/a/b/deleted.vue')).toBe('D')
    expect(
      wrapper.get('[data-testid="sidebar-diff-file-untracked-loose/untracked.ts"] > span').text(),
    ).toBe('?')
    // No status emoji anywhere in the panel — the letter chips replaced all six.
    // Written as code points so the assertion is not itself a surrogate-pair
    // character class (which oxlint rejects, rightly).
    const STATUS_EMOJI = /[\u{1F4DD}\u{2795}\u{1F5D1}\u{1F504}\u{1F4CB}\u{2753}]/u
    expect(wrapper.text()).not.toMatch(STATUS_EMOJI)
  })

  it('splits a path into a dim directory and a bright filename', async () => {
    // The whole point of the redesign: across 40 rows the shared `src/a/b/` prefix becomes
    // skippable and the name is what the eye lands on. Both halves stay in the DOM so `.text()`
    // still carries the full path.
    const { wrapper } = await mountPanel()
    const row = wrapper.get('[data-testid="sidebar-diff-file-unstaged-src/a/b/modified.vue"]')
    // The two halves of the path are the only coloured spans in the row;
    // the status chip carries a background, not a colour.
    const halves = row
      .findAll('span')
      .filter((s) => s.attributes('style')?.includes('color: var(--semantic'))
    expect(halves.map((s) => s.text())).toEqual(['src/a/b/', 'modified.vue'])
    expect(halves[0]!.attributes('style')).toBe('color: var(--semantic-text-dim);')
    expect(halves[1]!.attributes('style')).toBe('color: var(--semantic-text);')
    // Both halves stay in the DOM, so the full path is still readable and
    // assertable even though the visible emphasis is on the filename.
    expect(row.text()).toContain('src/a/b/modified.vue')
    expect(row.attributes('title')).toBe('src/a/b/modified.vue')
  })

  it('renders a root-level path with no directory half at all', async () => {
    const { wrapper } = await mountPanel()
    const row = wrapper.get('[data-testid="sidebar-diff-file-untracked-loose/untracked.ts"]')
    expect(row.text()).toContain('loose/untracked.ts')
  })
})

describe('SidebarDiffPanel chrome — the filter', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 0,
      commits: [],
    })
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
      changed_files: 12,
    })
  })

  it('stays hidden on a short list — a three-file panel gets no search box', async () => {
    getGitChangesMock.mockResolvedValue(BASE_CHANGES)
    const { wrapper } = await mountPanel()
    expect(wrapper.find('[data-testid="sidebar-file-filter"]').exists()).toBe(false)
  })

  it('appears past the row threshold, on both the worktree and the PR list', async () => {
    const many = {
      ...BASE_CHANGES,
      modified_files: Array.from({ length: 9 }, (_, i) => ({
        index_status: ' ',
        worktree_status: 'M',
        path: `src/a/b/file${i}.vue`,
      })),
    }
    getGitChangesMock.mockResolvedValue(many)
    const worktree = await mountPanel()
    expect(worktree.wrapper.find('[data-testid="sidebar-file-filter"]').exists()).toBe(true)

    const pr = await mountPanel({
      prUrl: 'https://github.com/acme/app/pull/42',
      prProvider: 'github',
    })
    expect(pr.wrapper.find('[data-testid="sidebar-file-filter"]').exists()).toBe(true)
  })

  it('narrows the list, case-insensitively, and says so when nothing matches', async () => {
    const many = {
      ...BASE_CHANGES,
      modified_files: Array.from({ length: 9 }, (_, i) => ({
        index_status: ' ',
        worktree_status: 'M',
        path: `src/a/b/file${i}.vue`,
      })),
      untracked_files: [],
    }
    getGitChangesMock.mockResolvedValue(many)
    const { wrapper } = await mountPanel()

    await wrapper.get('[data-testid="sidebar-file-filter"]').setValue('FILE3')
    await flushPromises()

    // file3.vue only — one row, and its group header reports the narrowed
    // count so the number on screen matches what is on screen.
    expect(wrapper.findAll('[data-testid^="sidebar-diff-file-unstaged-"]')).toHaveLength(1)
    expect(
      wrapper.find('[data-testid="sidebar-diff-file-unstaged-src/a/b/file3.vue"]').exists(),
    ).toBe(true)
    expect(wrapper.text()).toContain('Changes (1)')

    await wrapper.get('[data-testid="sidebar-file-filter"]').setValue('nothing-matches-this')
    await flushPromises()
    expect(wrapper.findAll('[data-testid^="sidebar-diff-file-unstaged-"]')).toHaveLength(0)
    expect(wrapper.text()).toContain('No files match')
  })

  it('keeps the filter out of the URL — it is transient text, not a view switch', async () => {
    // ?panel= / ?sidebar= / ?conflicts= own every piece of state that must
    // survive a reload. A filter in the URL would make Back/Forward step
    // through keystrokes.
    const many = {
      ...BASE_CHANGES,
      modified_files: Array.from({ length: 9 }, (_, i) => ({
        index_status: ' ',
        worktree_status: 'M',
        path: `src/a/b/file${i}.vue`,
      })),
    }
    getGitChangesMock.mockResolvedValue(many)
    const { wrapper, router } = await mountPanel()
    await wrapper.get('[data-testid="sidebar-file-filter"]').setValue('file1')
    await flushPromises()
    expect(router.currentRoute.value.query.panel).toBeUndefined()
    expect(JSON.stringify(router.currentRoute.value.query)).not.toContain('file1')
  })
})

describe('SidebarDiffPanel chrome — the tab strip', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(BASE_CHANGES)
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 0,
      commits: [],
    })
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
      changed_files: 12,
    })
  })

  it('uses one-word labels with the count in a pill, not "(43)" in the label', async () => {
    // "Pull request (43)" is 148px; "PR" plus a pill is 46px. That is the
    // whole reason five tabs now fit at the 200px minimum.
    const { wrapper } = await mountPanel({
      prUrl: 'https://github.com/acme/app/pull/42',
      prProvider: 'github',
    })
    const prTab = wrapper.get('[data-testid="sidebar-tab-pr"]')
    expect(prTab.text()).toContain('PR')
    expect(prTab.text()).not.toContain('(')
    expect(prTab.text()).toContain('12')
    expect(wrapper.get('[data-testid="sidebar-tab-files"]').text()).not.toContain('(')
  })

  it('says MR, not PR, for GitLab — the icon and the prose agree', async () => {
    const { wrapper } = await mountPanel({
      prUrl: 'https://gitlab.com/acme/app/-/merge_requests/8',
      prProvider: 'gitlab',
    })
    expect(wrapper.get('[data-testid="sidebar-tab-pr"]').text()).toContain('MR')
  })

  it('has exactly one refresh control, and it lives in the strip', async () => {
    const pr = await mountPanel({
      prUrl: 'https://github.com/acme/app/pull/42',
      prProvider: 'github',
    })
    expect(pr.wrapper.findAll('[data-testid="sidebar-diff-refresh"]')).toHaveLength(1)
    const git = await mountPanel()
    expect(git.wrapper.findAll('[data-testid="sidebar-diff-refresh"]')).toHaveLength(1)
  })

  it('names the forge with its own mark, not a shared emoji', async () => {
    const gh = await mountPanel({
      prUrl: 'https://github.com/acme/app/pull/42',
      prProvider: 'github',
    })
    const ghIcon = gh.wrapper.get('[data-testid="sidebar-pr-forge-icon"]')
    expect(ghIcon.attributes('data-forge')).toBe('github')
    expect(ghIcon.find('path').attributes('d')).toContain('M12 .297c-6.63')

    const gl = await mountPanel({
      prUrl: 'https://gitlab.com/acme/app/-/merge_requests/8',
      prProvider: 'gitlab',
    })
    const glIcon = gl.wrapper.get('[data-testid="sidebar-pr-forge-icon"]')
    expect(glIcon.attributes('data-forge')).toBe('gitlab')
    expect(glIcon.find('path').attributes('d')).not.toContain('M12 .297c-6.63')
  })
})
