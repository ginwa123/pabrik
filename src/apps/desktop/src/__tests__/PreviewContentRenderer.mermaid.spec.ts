/** Mermaid in the present_files preview path: a presented `.md` whose diagram blocks draw, and a
 * presented `.mmd` which IS the diagram. Mermaid is mocked (jsdom has no layout). */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

const { initializeMock, renderMock } = vi.hoisted(() => ({
  initializeMock: vi.fn(),
  renderMock: vi.fn(),
}))

vi.mock('mermaid', () => ({ default: { initialize: initializeMock, render: renderMock } }))

import PreviewContentRenderer from '../components/preview/PreviewContentRenderer.vue'
import { _resetMermaidLoader } from '../helpers/mermaid'

const SOURCE = 'flowchart TD\n  A[Prompt] --> B[Diagram]'

beforeEach(() => {
  _resetMermaidLoader()
  initializeMock.mockClear()
  renderMock.mockReset()
  renderMock.mockResolvedValue({ svg: '<svg data-rendered="yes"></svg>' })
})

describe('PreviewContentRenderer — mermaid', () => {
  it('draws a ```mermaid fence inside a presented markdown file, prose intact', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: `Here is the **flow**:\n\n\`\`\`mermaid\n${SOURCE}\n\`\`\`` },
      },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="chat-mermaid"]').exists()).toBe(true)
    expect(renderMock.mock.calls[0]?.[1]).toBe(SOURCE)
    expect(wrapper.html()).toContain('<strong>flow</strong>')
  })

  it('draws a <mermaid> block inside a presented markdown file', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: { contentType: 'markdown', args: { content: `<mermaid>${SOURCE}</mermaid>` } },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="chat-mermaid"]').exists()).toBe(true)
    expect(renderMock.mock.calls[0]?.[1]).toBe(SOURCE)
  })

  it('renders an html block inside a presented markdown file inline, not as nothing', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: 'before\n<html><b>live</b></html>\nafter' },
      },
    })
    await flushPromises()

    // This pane has no per-segment frame, so an `html` segment must keep
    // rendering inline — splitting the file out must not drop the block.
    expect(wrapper.html()).toContain('<b>live</b>')
    expect(wrapper.text()).toContain('before')
    expect(wrapper.text()).toContain('after')
  })

  it('draws a whole-file mermaid payload (.mmd) with no fence to strip', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: { contentType: 'mermaid', args: { content: SOURCE } },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="preview-mermaid"]').exists()).toBe(true)
    expect(renderMock.mock.calls[0]?.[1]).toBe(SOURCE)
  })

  it('leaves markdown with no mermaid exactly as before', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: { contentType: 'markdown', args: { content: '# Title\n\nsome **bold** text' } },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="chat-mermaid"]').exists()).toBe(false)
    expect(renderMock).not.toHaveBeenCalled()
    expect(wrapper.html()).toContain('<h1')
  })
})
