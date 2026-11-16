import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import GitFileViewer from '../GitFileViewer.vue'
import { clearFolderDiffCache, primeFolderDiffs } from '../../../helpers/folderDiffCache'

const { getGitFolderDiffsMock } = vi.hoisted(() => ({ getGitFolderDiffsMock: vi.fn() }))

vi.mock('../../../api', () => ({
  getGitFolderDiffs: getGitFolderDiffsMock,
}))

const DIFF = ['@@ -1,1 +1,1 @@', '-old line', '+new line'].join('\n')

describe('GitFileViewer', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearFolderDiffCache()
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
  })

  it('has no Wrap toggle and soft-wraps diff lines by default', async () => {
    const wrapper = mount(GitFileViewer, {
      props: { cwd: '/repo', filePath: 'dirty.txt', fileName: 'dirty.txt' },
    })
    await flushPromises()
    expect(wrapper.text()).not.toContain('Wrap')
    expect(wrapper.find('button[title="Toggle word wrap"]').exists()).toBe(false)
    expect(wrapper.find('.diff-wrap').exists()).toBe(true)
  })

  it('reads the shared snapshot when the diff panel already fetched the repo', async () => {
    // This is the real flow: the panel primes the whole repo, then the standalone viewer opens a file that is already in that payload.
    primeFolderDiffs('/repo', [{ path: 'dirty.txt', diff_content: DIFF, staged: false }])
    const wrapper = mount(GitFileViewer, {
      props: { cwd: '/repo', filePath: 'dirty.txt', fileName: 'dirty.txt' },
    })
    await flushPromises()
    expect(getGitFolderDiffsMock).not.toHaveBeenCalled()
    expect(wrapper.text()).toContain('new line')
  })

  it('falls back to ONE folder request when nothing is primed', async () => {
    const wrapper = mount(GitFileViewer, {
      props: { cwd: '/repo', filePath: 'dirty.txt', fileName: 'dirty.txt' },
    })
    await flushPromises()
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    // Never the per-file endpoint — that is the one request-per-file path.
    expect(wrapper.text()).toContain('new line')
  })

  it('shows an error when the folder fetch fails, not an empty diff', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    getGitFolderDiffsMock.mockRejectedValue(new Error('backend down'))
    const wrapper = mount(GitFileViewer, {
      props: { cwd: '/repo', filePath: 'dirty.txt', fileName: 'dirty.txt' },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Failed to load file diff')
  })
})
