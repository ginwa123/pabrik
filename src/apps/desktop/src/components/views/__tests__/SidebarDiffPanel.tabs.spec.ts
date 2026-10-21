import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

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
  staged_files: [],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [],
}

const DIFF = `diff --git a/dirty.txt b/dirty.txt
--- a/dirty.txt
+++ b/dirty.txt
@@ -1,2 +1,2 @@
 keep
-old
+new`

describe('SidebarDiffPanel tabs', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 1,
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
      changed_files: 2,
    })
  })

  it('with prUrl shows tabs with PR active by default', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-tab-files"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-tab-pr"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="sidebar-tab-pr"]').attributes('aria-selected')).toBe('true')
    expect(wrapper.get('[data-testid="sidebar-tab-files"]').attributes('aria-selected')).toBe(
      'false',
    )
    expect(wrapper.find('[data-testid="sidebar-pr-file-foo.txt"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(
      false,
    )
  })

  it('clicking Files loads and renders worktree rows, clicking PR goes back', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(getGitChangesMock).not.toHaveBeenCalled()
    await wrapper.get('[data-testid="sidebar-tab-files"]').trigger('click')
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    expect(wrapper.get('[data-testid="sidebar-tab-files"]').attributes('aria-selected')).toBe(
      'true',
    )
    expect(wrapper.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-pr-file-foo.txt"]').exists()).toBe(false)
    await wrapper.get('[data-testid="sidebar-tab-pr"]').trigger('click')
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-tab-pr"]').attributes('aria-selected')).toBe('true')
    expect(wrapper.find('[data-testid="sidebar-pr-file-foo.txt"]').exists()).toBe(true)
    expect(getPrDiffMock).toHaveBeenCalledTimes(1)
  })

  it('without prUrl the Files tab is the only file-list tab, and PR is hidden', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    // The Files tab carries the WORKING TREE list, which exists with or
    // without a PR — gating it on isPrMode is what forced the old
    // `Files | Commits` header toggle to exist as the only way back.
    expect(wrapper.find('[data-testid="sidebar-tab-files"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="sidebar-tab-files"]').attributes('aria-selected')).toBe(
      'true',
    )
    // Only the PR tab needs a PR.
    expect(wrapper.find('[data-testid="sidebar-tab-pr"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(true)
    // And there is no second control for the same two destinations.
    expect(wrapper.find('[data-testid="sidebar-diff-commits-toggle"]').exists()).toBe(false)
  })

  it('active tab is bright with an underline, inactive stays readable', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    const prStyle = wrapper.get('[data-testid="sidebar-tab-pr"]').attributes('style') ?? ''
    expect(prStyle).toContain('var(--semantic-text)')
    expect(prStyle).toContain('inset 0 -2px')
    const filesStyle = wrapper.get('[data-testid="sidebar-tab-files"]').attributes('style') ?? ''
    expect(filesStyle).toContain('var(--semantic-text)')
    expect(filesStyle).not.toContain('inset 0 -2px')
  })

  it('tab clicks sync ?panel= to the URL and mount restores it', async () => {
    const makeRouter = async (query: Record<string, string>) => {
      const r = createRouter({
        history: createMemoryHistory(),
        routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
      })
      await r.push({ path: '/', query })
      await r.isReady()
      return r
    }
    const router = await makeRouter({})
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [router] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-tab-files"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.panel).toBe('files')
    await wrapper.get('[data-testid="sidebar-tab-pr"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.panel).toBe('pr')

    const filesRouter = await makeRouter({ panel: 'files' })
    const restored = mount(SidebarDiffPanel, {
      global: { plugins: [filesRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(restored.get('[data-testid="sidebar-tab-files"]').attributes('aria-selected')).toBe(
      'true',
    )
    expect(restored.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(
      true,
    )
  })

  it('commits tab syncs ?panel=commits to the URL and mount restores it', async () => {
    const makeRouter = async (query: Record<string, string>) => {
      const r = createRouter({
        history: createMemoryHistory(),
        routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
      })
      await r.push({ path: '/', query })
      await r.isReady()
      return r
    }
    const router = await makeRouter({})
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [router] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-tab-commits"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.panel).toBe('commits')
    expect(wrapper.get('[data-testid="sidebar-tab-commits"]').attributes('aria-selected')).toBe(
      'true',
    )
    expect(getGitCommitsMock).toHaveBeenCalledWith('/repo', 100, 0)

    const commitsRouter = await makeRouter({ panel: 'commits' })
    const restored = mount(SidebarDiffPanel, {
      global: { plugins: [commitsRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(restored.get('[data-testid="sidebar-tab-commits"]').attributes('aria-selected')).toBe(
      'true',
    )
    // Restoring commits must not fetch the files tab.
    expect(getGitChangesMock).not.toHaveBeenCalled()
  })

  it('without prUrl the Commits tab round-trips to Files and syncs the URL', async () => {
    const r = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
    })
    await r.push({ path: '/', query: {} })
    await r.isReady()
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [r] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    // Commits is NOT PR-only — history exists with or without a PR — so the
    // strip renders and Commits is clickable. Only the PR tab is gated.
    expect(wrapper.find('[data-testid="sidebar-tab-pr"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-tab-commits"]').exists()).toBe(true)
    await wrapper.get('[data-testid="sidebar-tab-commits"]').trigger('click')
    await flushPromises()
    expect(r.currentRoute.value.query.panel).toBe('commits')
    expect(getGitCommitsMock).toHaveBeenCalledWith('/repo', 100, 0)
    // Back to the working tree, via the tab that is always there — no second
    // "Files" button is needed now that Files is not gated on isPrMode.
    await wrapper.get('[data-testid="sidebar-tab-files"]').trigger('click')
    await flushPromises()
    expect(r.currentRoute.value.query.panel).toBe('files')
    expect(wrapper.find('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').exists()).toBe(true)
  })
})

describe('SidebarDiffPanel without a router', () => {
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

  it('switches tabs instead of throwing when there is no router to keep in sync', async () => {
    // A standalone mount (the harness, a unit mount) has no router: there is no URL to write the
    // tab into, and the panel said so when it read the URL. The write must not throw.
    const errors: unknown[] = []
    const wrapper = mount(SidebarDiffPanel, {
      global: { config: { errorHandler: (err: unknown) => errors.push(err) } },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-tab-conversation"]').trigger('click')
    await flushPromises()
    expect(errors).toEqual([])
    expect(wrapper.get('[data-testid="sidebar-tab-conversation"]').attributes('aria-selected')).toBe(
      'true',
    )
  })
})
