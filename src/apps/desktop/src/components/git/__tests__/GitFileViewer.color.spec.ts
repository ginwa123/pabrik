/**
 * Code color in the git file viewer.
 *
 * `GitFileViewer` renders the SAME parsed unified diff as the review
 * sidebar, and used to render its code lines monochrome via
 * `v-html="escapeDiffHtml(line.content)"`. It now tokenizes them with the
 * shared highlighter, so both surfaces read identically.
 *
 * The language comes from the file path the viewer was opened with: a `.ts`
 * file is colored, an unknown extension is plain — the same contract the
 * diff review keeps.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import GitFileViewer from '../GitFileViewer.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const { getGitFolderDiffsMock } = vi.hoisted(() => ({ getGitFolderDiffsMock: vi.fn() }))

vi.mock('../../../api', () => ({
  getGitFolderDiffs: getGitFolderDiffsMock,
}))

const TS_DIFF = ['@@ -1,3 +1,3 @@', ' const kept = 1', '-const gone = 2', '+const added = 3'].join(
  '\n',
)

function prime(path: string, diff: string) {
  getGitFolderDiffsMock.mockResolvedValue({
    diffs: [{ path, diff_content: diff, staged: false }],
  })
}

async function mountViewer(filePath: string, diff: string) {
  prime(filePath, diff)
  const wrapper = mount(GitFileViewer, {
    props: { cwd: '/repo', filePath, fileName: filePath },
  })
  await flushPromises()
  return wrapper
}

describe('GitFileViewer — code color', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearFolderDiffCache()
  })

  it('tokenizes added, removed and context lines', async () => {
    const wrapper = await mountViewer('src/demo.ts', TS_DIFF)
    expect(wrapper.findAll('.tok-keyword').map((s) => s.text())).toEqual([
      'const',
      'const',
      'const',
    ])
    expect(wrapper.findAll('.tok-number').map((s) => s.text())).toEqual(['1', '2', '3'])
  })

  it('keeps the change sign glued to the code, with no stray whitespace', async () => {
    const wrapper = await mountViewer('src/demo.ts', TS_DIFF)
    // The sign is its own span and the code is now one span per token:
    // a newline between inline spans must not render as a space.
    expect(wrapper.text()).toContain('+const added = 3')
    expect(wrapper.text()).toContain('-const gone = 2')
  })

  it('keeps the row tint that marks added/removed', async () => {
    const wrapper = await mountViewer('src/demo.ts', TS_DIFF)
    expect(wrapper.findAll('.diff-line-add').length).toBeGreaterThan(0)
    expect(wrapper.findAll('.diff-line-remove').length).toBeGreaterThan(0)
  })

  it('renders an unknown extension as plain text, unchanged', async () => {
    const wrapper = await mountViewer('dirty.txt', TS_DIFF)
    expect(wrapper.findAll('.tok-keyword')).toHaveLength(0)
    expect(wrapper.findAll('.tok-plain').length).toBeGreaterThan(0)
    expect(wrapper.text()).toContain('const added = 3')
  })
})
