/** Behavioural tests for <MermaidDiagram> — the transcript's `<mermaid>` block renderer. Mermaid
 * itself is mocked: jsdom has no layout, and the component's contract is "draw what mermaid
 * returned, or show the source", not "mermaid parses". */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

const { initializeMock, renderMock } = vi.hoisted(() => ({
  initializeMock: vi.fn(),
  renderMock: vi.fn(),
}))

vi.mock('mermaid', () => ({ default: { initialize: initializeMock, render: renderMock } }))

import MermaidDiagram from '../MermaidDiagram.vue'
import { MERMAID_PALETTE_FALLBACK, _resetMermaidLoader } from '../../../helpers/mermaid'
import { applyTheme } from '../../../theme/runtime'

const SOURCE = 'flowchart TD\n  A[Prompt] --> B[Diagram]'

const mountDiagram = (source: string) => mount(MermaidDiagram, { props: { source } })

/** jsdom has no layout, so the column width a component measures has to be stubbed. */
const originalClientWidth = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth')
const stubColumnWidth = (width: number): void => {
  Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
    configurable: true,
    get: () => width,
  })
}

afterEach(() => {
  applyTheme(document.documentElement, 'dark')
  if (originalClientWidth) {
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', originalClientWidth)
    return
  }
  delete (HTMLElement.prototype as unknown as { clientWidth?: number }).clientWidth
})

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

  it('opens the full-screen viewer on click, and locks the page behind it', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()
    expect(document.querySelector('[data-testid="diagram-viewer"]')).toBeNull()

    await wrapper.find('[data-testid="chat-mermaid-enlarge"]').trigger('click')
    const viewer = document.querySelector('[data-testid="diagram-viewer"]')
    expect(viewer).not.toBeNull()
    // The viewer shows the same drawing, with room and controls to read it.
    expect(
      viewer?.querySelector('[data-testid="diagram-viewer-content"] svg'),
    ).not.toBeNull()
    expect(viewer?.getAttribute('aria-label')).toBe('Mermaid diagram')
    expect(document.body.style.overflow).toBe('hidden')

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await flushPromises()
    expect(document.querySelector('[data-testid="diagram-viewer"]')).toBeNull()
    expect(document.body.style.overflow).toBe('')
  })

  it('closes the viewer from its own close button', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()
    await wrapper.find('[data-testid="chat-mermaid-enlarge"]').trigger('click')
    ;(document.querySelector('[data-testid="diagram-viewer-close"]') as HTMLElement).click()
    await flushPromises()
    expect(document.querySelector('[data-testid="diagram-viewer"]')).toBeNull()
  })

  it('zooms in and back to fit from the viewer toolbar', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()
    await wrapper.find('[data-testid="chat-mermaid-enlarge"]').trigger('click')

    const zoom = (): string =>
      document.querySelector('[data-testid="diagram-viewer-zoom"]')?.textContent ?? ''
    expect(zoom()).toBe('100%')

    ;(document.querySelector('[data-testid="diagram-viewer-zoom-in"]') as HTMLElement).click()
    await flushPromises()
    expect(zoom()).toBe('125%')

    ;(document.querySelector('[data-testid="diagram-viewer-fit"]') as HTMLElement).click()
    await flushPromises()
    expect(zoom()).toBe('100%')
  })

  it('redraws the drawing inside the open viewer when the theme flips', async () => {
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()
    await wrapper.find('[data-testid="chat-mermaid-enlarge"]').trigger('click')
    expect(
      document
        .querySelector('[data-testid="diagram-viewer-content"] svg')
        ?.getAttribute('data-rendered'),
    ).toBe('yes')

    renderMock.mockResolvedValue({ svg: '<svg data-rendered="light"><text>A</text></svg>' })
    applyTheme(document.documentElement, 'light')
    await flushPromises()

    // The SVG bakes literal colours, so the theme flip has to rebuild it — in the viewer too.
    expect(
      document
        .querySelector('[data-testid="diagram-viewer-content"] svg')
        ?.getAttribute('data-rendered'),
    ).toBe('light')
    expect(wrapper.find('[data-testid="chat-mermaid-svg"] svg').attributes('data-rendered')).toBe(
      'light',
    )
  })

  it('keeps a diagram wider than the column at a legible width, and says it is wider', async () => {
    renderMock.mockResolvedValue({ svg: '<svg viewBox="0 0 3000 600"><text>A</text></svg>' })
    stubColumnWidth(800)
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()

    const enlarge = wrapper.find('[data-testid="chat-mermaid-enlarge"]')
    const width = Number(/width:\s*([\d.]+)px/.exec(enlarge.attributes('style') ?? '')?.[1])
    // 3000px of drawing in an 800px column would be 27% — unreadable labels. It keeps 75%.
    expect(width).toBe(2250)
    expect(width).toBeGreaterThan(800)
    expect(wrapper.find('[data-testid="chat-mermaid-wide"]').exists()).toBe(true)
  })

  it('copies the mermaid source, and says so on the button', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    const wrapper = mountDiagram(SOURCE)
    await flushPromises()

    await wrapper.find('[data-testid="chat-mermaid-copy"]').trigger('click')
    await flushPromises()

    expect(writeText).toHaveBeenCalledWith(SOURCE)
    expect(wrapper.find('[data-testid="chat-mermaid-copy"]').classes()).toContain(
      'chat-mermaid-copy--done',
    )
    expect(wrapper.find('[data-testid="chat-mermaid-copy"]').attributes('aria-label')).toBe(
      'Copied',
    )
  })
})
