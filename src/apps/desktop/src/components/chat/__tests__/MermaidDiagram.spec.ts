/** Behavioural tests for <MermaidDiagram> — the transcript's `<mermaid>` block renderer. Mermaid
 * itself is mocked: jsdom has no layout, and the component's contract is "draw what mermaid
 * returned, or show the source", not "mermaid parses". */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

const { initializeMock, renderMock } = vi.hoisted(() => ({
  initializeMock: vi.fn(),
  renderMock: vi.fn(),
}))

vi.mock('mermaid', () => ({ default: { initialize: initializeMock, render: renderMock } }))

import MermaidDiagram from '../MermaidDiagram.vue'
import { MERMAID_PALETTE_FALLBACK, _resetMermaidLoader } from '../../../helpers/mermaid'

const SOURCE = 'flowchart TD\n  A[Prompt] --> B[Diagram]'

const mountDiagram = (source: string) => mount(MermaidDiagram, { props: { source } })

beforeEach(() => {
  _resetMermaidLoader()
  initializeMock.mockClear()
  renderMock.mockReset()
  renderMock.mockResolvedValue({ svg: '<svg data-rendered="yes"><text>A</text></svg>' })
})

describe('MermaidDiagram', () => {
  it('draws the svg mermaid returned, and passes it the block source', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()

    const canvas = wrapper.find('[data-testid="chat-mermaid-svg"]')
    expect(canvas.exists()).toBe(true)
    expect(canvas.html()).toContain('data-rendered="yes"')
    expect(renderMock).toHaveBeenCalledTimes(1)
    expect(renderMock.mock.calls[0]?.[1]).toBe(SOURCE)
  })

  it('initializes mermaid once, with the app palette and a fresh id per call', async () => {
    mountDiagram(SOURCE)
    await flushPromises()
    mountDiagram('graph LR\n  X --> Y')
    await flushPromises()

    expect(initializeMock).toHaveBeenCalledTimes(1)
    const config = initializeMock.mock.calls[0]?.[0] as {
      startOnLoad: boolean
      securityLevel: string
      theme: string
      htmlLabels: boolean
      suppressErrorRendering: boolean
      themeVariables: { darkMode: boolean; background: string; lineColor: string }
    }
    expect(config.startOnLoad).toBe(false)
    expect(config.securityLevel).toBe('strict')
    expect(config.theme).toBe('base')
    // Root-level: mermaid 12 deprecated `flowchart.htmlLabels`, and HTML labels
    // would inherit the transcript's Tailwind preflight inside the diagram.
    expect(config.htmlLabels).toBe(false)
    // A diagram mermaid cannot parse must REJECT, not draw its "Syntax error"
    // graphic into the page (which is what appears at the bottom of the chat).
    expect(config.suppressErrorRendering).toBe(true)
    expect(config.themeVariables.darkMode).toBe(true)
    // Canvas is the card surface, not a white sheet on a dark transcript.
    expect(config.themeVariables.background).toBe(MERMAID_PALETTE_FALLBACK.canvas)
    expect(config.themeVariables.lineColor).toBe(MERMAID_PALETTE_FALLBACK.line)

    // A shared id would make the second diagram inherit the first's stylesheet.
    expect(renderMock.mock.calls[0]?.[0]).not.toBe(renderMock.mock.calls[1]?.[0])
  })

  it('falls back to the source, with the reason, when the diagram does not parse', async () => {
    renderMock.mockRejectedValue(new Error('Parse error on line 2:\n  A[unclosed\nExpecting X'))
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()

    // No diagram: the fallback replaces it entirely.
    expect(wrapper.find('[data-testid="chat-mermaid-svg"]').exists()).toBe(false)
    const note = wrapper.find('[data-testid="chat-mermaid-error"]')
    expect(note.text()).toContain('Parse error on line 2')
    // Only the first line: the rest is the payload the block already shows.
    expect(note.text()).not.toContain('Expecting X')
    expect(wrapper.find('.chat-mermaid-source').text()).toBe(SOURCE)
  })

  it('re-draws only when the source changes', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()
    expect(renderMock).toHaveBeenCalledTimes(1)

    // A parent re-render with the same text (a streaming sibling) must not
    // re-render the diagram.
    await wrapper.setProps({ source: SOURCE })
    await flushPromises()
    expect(renderMock).toHaveBeenCalledTimes(1)

    await wrapper.setProps({ source: 'graph LR\n  X --> Y' })
    await flushPromises()
    expect(renderMock).toHaveBeenCalledTimes(2)
  })

  it('ignores a slow render that resolves after a newer one', async () => {
    let resolveFirst: (value: { svg: string }) => void = () => {}
    renderMock.mockImplementationOnce(
      () =>
        new Promise<{ svg: string }>((resolve) => {
          resolveFirst = resolve
        }),
    )
    const wrapper = mountDiagram('graph LR\n  OLD --> X')
    await flushPromises()

    await wrapper.setProps({ source: 'graph LR\n  NEW --> X' })
    await flushPromises()
    expect(wrapper.find('[data-testid="chat-mermaid-svg"]').html()).toContain('data-rendered="yes"')

    resolveFirst({ svg: '<svg data-rendered="stale"></svg>' })
    await flushPromises()
    expect(wrapper.find('[data-testid="chat-mermaid-svg"]').html()).not.toContain('stale')
  })
})
