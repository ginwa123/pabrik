/** Conflict-only PR UI for SidebarDiffPanel (quiet-when-clean). Contract: CONFLICTING/DIRTY shows
 * the red "Merge conflicts" badge plus the "This branch has conflicts that must be resolved" banner
 * with a Resolve link to <pr-url>/conflicts. */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { ApiError } from '../../../api'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const {
  getGitChangesMock,
  getPrDiffMock,
  getPrStatusMock,
  getPrConflictsMock,
  stageGitFilesMock,
  pushMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
  getPrConflictsMock: vi.fn(),
  stageGitFilesMock: vi.fn(),
  pushMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
    getPrConflicts: getPrConflictsMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: vi.fn(),
  }
})

vi.mock('../../../helpers/openInNewTab', () => ({ openInNewTab: pushMock }))

const PR_DIFF = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1 +1 @@
-old
+new`

function prStatusPayload(overrides: Record<string, string> = {}) {
  return {
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
    changed_files: 1,
    ...overrides,
  }
}

function conflictsPayload(conflicting_files: string[], overrides: Record<string, unknown> = {}) {
  return {
    pr_url: 'https://github.com/acme/app/pull/42',
    base_ref: 'refs/remotes/origin/main',
    base_commit: 'fb7b2dc4ec',
    head: 'HEAD',
    conflicting_files,
    count: conflicting_files.length,
    truncated: false,
    ...overrides,
  }
}

function mountPrPanel(initialQuery: Record<string, string> = {}) {
  return mount(SidebarDiffPanel, {
    global: { plugins: [testRouter] },
    props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', prProvider: 'github' },
    ...(Object.keys(initialQuery).length ? {} : {}),
  })
}

describe('SidebarDiffPanel PR conflict UI', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    clearFolderDiffCache()
    await testRouter.replace({ path: '/', query: {} })
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/42',
      base: 'main',
      head: 'feature',
      diff_content: PR_DIFF,
      truncated: false,
    })
    getPrStatusMock.mockResolvedValue(prStatusPayload())
    getPrConflictsMock.mockResolvedValue(conflictsPayload([]))
  })

  it('shows the conflict badge and banner when mergeable is CONFLICTING', async () => {
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'CONFLICTING', merge_state: 'DIRTY' }),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-pr-conflict-badge"]').text()).toContain(
      'Merge conflicts',
    )
    const notice = wrapper.get('[data-testid="sidebar-pr-conflict-notice"]')
    expect(notice.text()).toContain('This branch has conflicts that must be resolved')
    expect(notice.find('a').attributes('href')).toBe(
      'https://github.com/acme/app/pull/42/conflicts',
    )
    // The Open badge stays alongside the conflict badge.
    expect(wrapper.get('[data-testid="sidebar-pr-status"]').text()).toBe('Open')
  })

  it('shows the conflict UI when only merge_state is DIRTY', async () => {
    getPrStatusMock.mockResolvedValue(prStatusPayload({ mergeable: '', merge_state: 'DIRTY' }))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(true)
  })

  it('stays quiet (no badge, no banner) when the PR is mergeable', async () => {
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'MERGEABLE', merge_state: 'CLEAN' }),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="sidebar-pr-status"]').text()).toBe('Open')
  })

  it('stays quiet when mergeable is unknown (today behavior)', async () => {
    getPrStatusMock.mockResolvedValue(prStatusPayload({ mergeable: '', merge_state: '' }))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(false)
  })
})

describe('SidebarDiffPanel conflicting-file list', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    clearFolderDiffCache()
    await testRouter.replace({ path: '/', query: {} })
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/42',
      base: 'main',
      head: 'feature',
      diff_content: PR_DIFF,
      truncated: false,
    })
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'CONFLICTING', merge_state: 'DIRTY' }),
    )
    getPrConflictsMock.mockResolvedValue(
      conflictsPayload(['tests/functional/default_tools.py', 'src/main.zig']),
    )
  })

  it('names the conflicting files under the badge and counts them in it', async () => {
    const wrapper = mountPrPanel()
    await flushPromises()

    expect(getPrConflictsMock).toHaveBeenCalled()
    const section = wrapper.get('[data-testid="sidebar-pr-conflict-files"]')
    expect(section.text()).toContain('Conflicting files (2)')
    expect(
      section
        .find('[data-testid="sidebar-pr-conflict-file-tests/functional/default_tools.py"]')
        .exists(),
    ).toBe(true)
    expect(section.find('[data-testid="sidebar-pr-conflict-file-src/main.zig"]').exists()).toBe(
      true,
    )
    expect(wrapper.get('[data-testid="sidebar-pr-conflict-badge"]').text()).toContain(
      'Merge conflicts (2)',
    )
    // Provenance line — an empty list is only meaningful next to the ref it
    // was computed from.
    expect(wrapper.get('[data-testid="sidebar-pr-conflict-base"]').text()).toContain(
      'refs/remotes/origin/main',
    )
  })

  it('passes the base and head the diff endpoint reported to the conflicts call', async () => {
    mountPrPanel()
    await flushPromises()
    expect(getPrConflictsMock).toHaveBeenCalledWith(
      '/repo',
      'https://github.com/acme/app/pull/42',
      expect.objectContaining({ base: 'main', head: 'feature', provider: 'github' }),
    )
  })

  it('never calls the conflicts endpoint when the PR is mergeable', async () => {
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'MERGEABLE', merge_state: 'CLEAN' }),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(getPrConflictsMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-files"]').exists()).toBe(false)
  })

  it('says "could not reproduce" instead of showing an empty list', async () => {
    getPrConflictsMock.mockResolvedValue(conflictsPayload([]))
    const wrapper = mountPrPanel()
    await flushPromises()
    // A red badge plus an empty file list reads as "nothing to do" — which is
    // the one thing that must never happen here.
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-files"]').exists()).toBe(false)
    const notice = wrapper.get('[data-testid="sidebar-pr-conflict-unreproduced"]')
    expect(notice.text()).toContain('Could not reproduce these conflicts locally')
    expect(notice.text()).toContain('refs/remotes/origin/main')
    // No count in the badge either — we do not know a count.
    expect(wrapper.get('[data-testid="sidebar-pr-conflict-badge"]').text()).not.toContain('(')
  })

  it('surfaces a conflicts-endpoint failure inline instead of silently', async () => {
    getPrConflictsMock.mockRejectedValue(
      new ApiError(422, 'Unprocessable', '{"error":"could not resolve base branch"}'),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    const err = wrapper.get('[data-testid="sidebar-pr-conflict-error"]')
    expect(err.text()).toContain('Could not list conflicting files')
    expect(err.text()).toContain('could not resolve base branch')
  })

  it('flags a truncated server list', async () => {
    getPrConflictsMock.mockResolvedValue(conflictsPayload(['a.zig', 'b.zig'], { truncated: true }))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-files-truncated"]').exists()).toBe(true)
  })

  it('clicking a conflicting file that is in the PR diff selects it', async () => {
    // foo.txt is the only file in PR_DIFF.
    getPrConflictsMock.mockResolvedValue(conflictsPayload(['foo.txt']))
    const wrapper = mountPrPanel()
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-conflict-file-foo.txt"]').trigger('click')
    expect(wrapper.emitted('show-diff')?.[0]?.[0]).toMatchObject({ path: 'foo.txt', staged: false })
    expect(pushMock).not.toHaveBeenCalled()
  })

  it('clicking a conflicting file outside the PR diff opens the editor', async () => {
    const wrapper = mountPrPanel()
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-conflict-file-src/main.zig"]').trigger('click')
    expect(pushMock).toHaveBeenCalledWith(
      testRouter,
      expect.objectContaining({
        query: expect.objectContaining({ view: 'code-editor', file: 'src/main.zig' }),
      }),
    )
  })

  it('toggling "conflicts only" writes ?conflicts=1 and narrows the file list', async () => {
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.findAll('[data-testid^="sidebar-pr-file-"]').length).toBe(1)

    await wrapper.get('[data-testid="sidebar-pr-conflicts-only"]').trigger('click')
    await flushPromises()
    expect(testRouter.currentRoute.value.query.conflicts).toBe('1')
    expect(
      wrapper.get('[data-testid="sidebar-pr-conflicts-only"]').attributes('aria-pressed'),
    ).toBe('true')
    // The list header reports the narrowed count against the total.
    expect(wrapper.text()).toContain('PR files (0 of 1)')

    await wrapper.get('[data-testid="sidebar-pr-conflicts-only"]').trigger('click')
    await flushPromises()
    expect(testRouter.currentRoute.value.query.conflicts).toBeUndefined()
    expect(
      wrapper.get('[data-testid="sidebar-pr-conflicts-only"]').attributes('aria-pressed'),
    ).toBe('false')
  })

  it('restores the conflicts-only filter from the URL on mount', async () => {
    await testRouter.replace({ path: '/', query: { panel: 'pr', conflicts: '1' } })
    getPrConflictsMock.mockResolvedValue(conflictsPayload(['foo.txt']))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(
      wrapper.get('[data-testid="sidebar-pr-conflicts-only"]').attributes('aria-pressed'),
    ).toBe('true')
    // foo.txt is the only PR file and it conflicts, so it stays visible.
    expect(wrapper.findAll('[data-testid^="sidebar-pr-file-"]').length).toBe(1)

    await testRouter.replace({ path: '/', query: {} })
  })
})
