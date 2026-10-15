/** CodeEditor git gutter — change bars, Code/Diff toggle, change navigator,
 * blame annotation. The diff and blame travel as props (presentational, like
 * `content`): the spec pins rendering, not fetching. */
import { describe, expect, it } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import CodeEditor from '../CodeEditor.vue'

const CONTENT = ['line1', 'line2', 'line3', 'line4'].join('\n')

const DIFF_TEXT = [
  'diff --git a/x.go b/x.go',
  'index 111..222 100644',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,2 +1,4 @@',
  ' line1',
  '+line2',
  '+line3',
  ' line4',
].join('\n')

const BLAME = [
  { line: 2, author: 'ginwa', age: '2 hours ago' },
  { line: 3, author: 'ginwa', age: '2 hours ago' },
]

describe('CodeEditor git gutter', () => {
  it('marks added lines with a gutter bar when diffText is provided', async () => {
    const wrapper = mount(CodeEditor, {
      props: { filePath: '/repo/x.go', fileName: 'x.go', content: CONTENT, diffText: DIFF_TEXT },
    })
    await flushPromises()
    const bars = wrapper.findAll('[data-testid="code-gutter"][data-kind="added"]')
    expect(bars.map((b) => b.attributes('data-line'))).toEqual(['2', '3'])
    wrapper.unmount()
  })

  it('renders no gutter bars without a diff', async () => {
    const wrapper = mount(CodeEditor, {
      props: { filePath: '/repo/x.go', fileName: 'x.go', content: CONTENT },
    })
    await flushPromises()
    expect(wrapper.findAll('[data-testid="code-gutter"]').length).toBe(0)
    wrapper.unmount()
  })

  it('toggles between Code and Diff views', async () => {
    const wrapper = mount(CodeEditor, {
      props: { filePath: '/repo/x.go', fileName: 'x.go', content: CONTENT, diffText: DIFF_TEXT },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="code-diff-view"]').exists()).toBe(false)
    await wrapper.find('[data-testid="code-diff-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="code-diff-view"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="code-diff-view"]').text()).toContain('+line2')
    wrapper.unmount()
  })

  it('navigates between change blocks with a counter', async () => {
    const wrapper = mount(CodeEditor, {
      props: { filePath: '/repo/x.go', fileName: 'x.go', content: CONTENT, diffText: DIFF_TEXT },
    })
    await flushPromises()
    // One block (lines 2-3) -> counter reads 1 / 1.
    expect(wrapper.find('[data-testid="change-nav"]').text()).toContain('1 / 1')
    await wrapper.find('[data-testid="change-next"]').trigger('click')
    expect(wrapper.find('[data-testid="code-line"][data-target="true"]') !== null).toBe(true)
    wrapper.unmount()
  })

  it('shows the blame annotation on annotated lines', async () => {
    const wrapper = mount(CodeEditor, {
      props: {
        filePath: '/repo/x.go',
        fileName: 'x.go',
        content: CONTENT,
        diffText: DIFF_TEXT,
        blame: BLAME,
      },
    })
    await flushPromises()
    const blames = wrapper.findAll('[data-testid="line-blame"]')
    expect(blames.length).toBe(2)
    expect(blames[0]?.text()).toContain('ginwa')
    expect(blames[0]?.text()).toContain('2 hours ago')
    wrapper.unmount()
  })
})
