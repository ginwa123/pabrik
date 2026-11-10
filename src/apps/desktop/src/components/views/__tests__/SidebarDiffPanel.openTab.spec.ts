import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { defineComponent, h, provide } from 'vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
} from '../../../composables/useCodeEditor'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const {
  getGitChangesMock,
  getGitFolderDiffsMock,
  getPrDiffMock,
  getPrStatusMock,
  getGitCommitsMock,
  getGitCommitDetailMock,
  getGitCommitFileDiffMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
  getGitCommitsMock: vi.fn(),
  getGitCommitDetailMock: vi.fn(),
  getGitCommitFileDiffMock: vi.fn(),
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
    getGitCommitDetail: getGitCommitDetailMock,
    getGitCommitFileDiff: getGitCommitFileDiffMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const DIFF = `diff --git a/dirty.txt b/dirty.txt
--- a/dirty.txt
+++ b/dirty.txt
@@ -1,2 +1,2 @@
 keep
-old
+new`

const COMMIT = {
  sha: '3bc0e389abc123def45678901234567890123456',
  short_sha: '3bc0e389',
  author: 'Alice Example',
  email: 'alice@x.io',
  timestamp: 1700000000,
  subject: 'feat(chat): prefetch older messages',
  body: '',
}

const makeRouter = async () => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/', query: {} })
  await router.isReady()
  return router
}

/** Mount the panel under a host that provides `openInCodeEditor`, the way AppLayout does. */
const mountWithEditor = async (
  props: { cwd: string; prUrl?: string },
  openInEditor: OpenInCodeEditorFn,
) => {
  const router = await makeRouter()
  const Host = defineComponent({
    setup() {
      provide(OPEN_IN_CODE_EDITOR_KEY, openInEditor)
      return () => h(SidebarDiffPanel, props)
    },
  })
  const wrapper = mount(Host, { global: { plugins: [router] } })
  await flushPromises()
  return wrapper
}

const panelOf = (wrapper: ReturnType<typeof mount>) => wrapper.findComponent(SidebarDiffPanel)

describe('SidebarDiffPanel file rows open an editor tab', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: true,
      staged_files: [],
      modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
      untracked_files: [],
    })
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/1',
      base: 'main',
      head: 'feature',
      diff_content: DIFF,
      truncated: false,
    })
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      title: 'Test',
      pr_url: 'https://github.com/acme/app/pull/1',
      number: 1,
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
    })
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 1,
      commits: [COMMIT],
    })
    getGitCommitDetailMock.mockResolvedValue({
      ...COMMIT,
      files: [{ status: 'M', path: 'src/main.zig' }],
    })
    getGitCommitFileDiffMock.mockResolvedValue({
      sha: COMMIT.sha,
      path: 'src/main.zig',
      diff_content: DIFF,
    })
  })

  it('opens a worktree file row in the editor tab instead of the center column', async () => {
    const openInEditor = vi.fn()
    const wrapper = await mountWithEditor({ cwd: '/repo' }, openInEditor)

    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()

    expect(openInEditor).toHaveBeenCalledTimes(1)
    expect(openInEditor).toHaveBeenCalledWith({ filePath: 'dirty.txt', cwd: '/repo' })
    expect(panelOf(wrapper).emitted('show-diff')).toBeUndefined()
  })

  it('opens a PR file row in the editor tab instead of the center column', async () => {
    const openInEditor = vi.fn()
    const wrapper = await mountWithEditor(
      { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/1' },
      openInEditor,
    )

    await wrapper.get('[data-testid="sidebar-pr-file-dirty.txt"]').trigger('click')
    await flushPromises()

    expect(openInEditor).toHaveBeenCalledTimes(1)
    expect(openInEditor).toHaveBeenCalledWith({ filePath: 'dirty.txt', cwd: '/repo' })
    expect(panelOf(wrapper).emitted('show-diff')).toBeUndefined()
  })

  it('opens a file inside a commit in the editor tab, without fetching its diff', async () => {
    const openInEditor = vi.fn()
    const wrapper = await mountWithEditor({ cwd: '/repo' }, openInEditor)

    await wrapper.get('[data-testid="sidebar-tab-commits"]').trigger('click')
    await flushPromises()
    const commitRow = wrapper.findAll('button').find((b) => b.text().includes('prefetch older'))
    await commitRow!.trigger('click')
    await flushPromises()
    const fileRow = wrapper.findAll('button').find((b) => b.text().includes('src/main.zig'))
    await fileRow!.trigger('click')
    await flushPromises()

    expect(openInEditor).toHaveBeenCalledTimes(1)
    expect(openInEditor).toHaveBeenCalledWith({ filePath: 'src/main.zig', cwd: '/repo' })
    expect(getGitCommitFileDiffMock).not.toHaveBeenCalled()
    expect(panelOf(wrapper).emitted('show-diff')).toBeUndefined()
  })

  it('keeps ctrl+click on a browser tab, not the editor tab', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const openInEditor = vi.fn()
      const wrapper = await mountWithEditor({ cwd: '/repo' }, openInEditor)

      await wrapper
        .get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
        .trigger('click', { ctrlKey: true })
      await flushPromises()

      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openInEditor).not.toHaveBeenCalled()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('falls back to the center column when no editor provider is mounted', async () => {
    const router = await makeRouter()
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [router] },
      props: { cwd: '/repo' },
    })
    await flushPromises()

    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()

    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'dirty.txt', staged: false })
  })
})
