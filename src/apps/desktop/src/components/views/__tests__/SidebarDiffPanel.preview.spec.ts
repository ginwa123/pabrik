import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const { getGitChangesMock, getPrDiffMock, getPrStatusMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
  }
})

const PR_DIFF = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1,3 +1,3 @@
 keep
-old line
+new line
 tail
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello`

const mountPanel = async () => {
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [testRouter] },
    props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', prProvider: 'github' },
  })
  await flushPromises()
  return wrapper
}

describe('SidebarDiffPanel — the before/after of the file you clicked', () => {
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

  it('shows nothing before a file is clicked', async () => {
    const wrapper = await mountPanel()
    expect(wrapper.find('[data-testid="sidebar-pr-file-preview"]').exists()).toBe(false)
  })

  it('shows the old line and the new line of the file you clicked', async () => {
    const wrapper = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()

    const preview = wrapper.get('[data-testid="sidebar-pr-file-preview"]')
    const lines = preview.findAll('[data-testid="sidebar-pr-file-preview-line"]').map((l) => l.text())
    expect(lines.join('\n')).toContain('old line')
    expect(lines.join('\n')).toContain('new line')
    // The before/after is signed: the reader must see which line is the old one.
    expect(preview.text()).toContain('−')
    expect(preview.text()).toContain('+')
  })

  it('keeps the file you clicked and its full name in the panel', async () => {
    const wrapper = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()
    // The preview belongs to the file under it, not to the last file of the list.
    expect(wrapper.get('[data-testid="sidebar-pr-file-preview"]').text()).toContain('old line')
  })

  it('puts the preview away when the same file is clicked again', async () => {
    const wrapper = await mountPanel()
    const row = wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]')
    await row.trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-file-preview"]').exists()).toBe(true)

    await row.trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-file-preview"]').exists()).toBe(false)
  })

  it('shows one file at a time: a second file replaces the first', async () => {
    const wrapper = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-new.txt"]').trigger('click')
    await flushPromises()

    const previews = wrapper.findAll('[data-testid="sidebar-pr-file-preview"]')
    expect(previews).toHaveLength(1)
    expect(previews[0]!.text()).toContain('hello')
    expect(previews[0]!.text()).not.toContain('old line')
  })

  it('still opens the file in the centre column when the row is clicked', async () => {
    const wrapper = await mountPanel()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'foo.txt', staged: false })
  })
})
