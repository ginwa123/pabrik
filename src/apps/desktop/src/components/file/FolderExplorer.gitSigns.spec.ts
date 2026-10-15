/** FolderExplorer git signs — badges, branch header, folder counts, filter,
 * footer summary. listFolder + getGitChanges are mocked; the spec pins the
 * join between the two (absolute explorer paths vs repo-relative git paths). */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import FolderExplorer from './FolderExplorer.vue'

const { listFolderMock, getGitChangesMock } = vi.hoisted(() => ({
  listFolderMock: vi.fn(),
  getGitChangesMock: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    listFolder: listFolderMock,
    getGitChanges: getGitChangesMock,
  }
})

const ENTRIES = [
  { path: '/repo/src', name: 'src', is_directory: true, is_symlink: false },
  { path: '/repo/app.ts', name: 'app.ts', is_directory: false, is_symlink: false },
  { path: '/repo/clean.ts', name: 'clean.ts', is_directory: false, is_symlink: false },
]

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [{ index_status: 'A', worktree_status: ' ', path: 'src/new.ts' }],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'app.ts' }],
  untracked_files: [{ index_status: '?', worktree_status: '?', path: 'notes/todo.md' }],
}

describe('FolderExplorer git signs', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    listFolderMock.mockResolvedValue({ entries: ENTRIES })
    getGitChangesMock.mockResolvedValue(CHANGES)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('fetches git changes for the cwd on mount', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    wrapper.unmount()
  })

  it('renders an M badge on the modified file and none on the clean file', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    const rows = wrapper.findAll('[data-testid="explorer-row"]')
    const appRow = rows.find((r) => r.text().includes('app.ts'))
    const cleanRow = rows.find((r) => r.text().includes('clean.ts'))
    expect(appRow?.find('[data-testid="git-badge"]').text()).toBe('M')
    expect(cleanRow?.find('[data-testid="git-badge"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('shows the branch name in the header', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(wrapper.find('[data-testid="git-branch"]').text()).toContain('main')
    wrapper.unmount()
  })

  it('rolls changed descendants into a folder count badge', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    const rows = wrapper.findAll('[data-testid="explorer-row"]')
    const srcRow = rows.find((r) => r.text().includes('src'))
    // src/new.ts is staged -> one changed descendant under src/.
    expect(srcRow?.find('[data-testid="folder-count"]').text()).toBe('1')
    wrapper.unmount()
  })

  it('filters rows by name as the user types', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.find('[data-testid="explorer-filter"]').setValue('app')
    const rows = wrapper.findAll('[data-testid="explorer-row"]')
    expect(rows.map((r) => r.text())).toEqual(
      expect.arrayContaining([expect.stringContaining('app.ts')]),
    )
    expect(rows.some((r) => r.text().includes('clean.ts'))).toBe(false)
    wrapper.unmount()
  })

  it('summarizes change counts in the footer', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    const footer = wrapper.find('[data-testid="explorer-footer"]').text()
    expect(footer).toContain('1 modified')
    expect(footer).toContain('1 staged')
    expect(footer).toContain('1 untracked')
    wrapper.unmount()
  })

  it('still emits file-click when a file row is clicked', async () => {
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    const rows = wrapper.findAll('[data-testid="explorer-row"]')
    await rows.find((r) => r.text().includes('app.ts'))!.trigger('click')
    expect(wrapper.emitted('file-click')?.[0]?.[0]).toMatchObject({ name: 'app.ts' })
    wrapper.unmount()
  })

  it('re-polls git changes every 30s and stops on unmount', async () => {
    vi.useFakeTimers()
    const wrapper = mount(FolderExplorer, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(30000)
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
    wrapper.unmount()
    await vi.advanceTimersByTimeAsync(60000)
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
  })
})
