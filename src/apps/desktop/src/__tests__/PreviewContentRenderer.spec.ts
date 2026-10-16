/**  * Behavioural tests for the <PreviewContentRenderer> component. The renderer renders text content
 * inline inside the chat bubble (used by <PresentFiles> for per-file text previews). Covers the
 * 5-branch pipeline (markdown / text / code / image / html) plus the HTML "Open in new tab" action. */
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import PreviewContentRenderer from '../components/preview/PreviewContentRenderer.vue'
import { FRAME_CANVAS_FALLBACK } from '@/helpers'

describe('PreviewContentRenderer (inline + new tab)', () => {
  it('renders markdown content via marked() into an <h1>', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: '# Title' },
      },
    })
    const html = wrapper.html()
    expect(html).toContain('Title')
    expect(html).toContain('<h1')
  })

  it('renders text content as a <pre> with preserved whitespace', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'text',
        args: { content: 'line 1\n  line 2 indented' },
      },
    })
    const html = wrapper.html()
    expect(html).toContain('<pre')
    expect(html).toContain('whitespace-pre-wrap')
  })

  it('renders code content with language class for syntax highlighting', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'code',
        args: { content: 'fn main() void {}', language: 'zig' },
      },
    })
    expect(wrapper.html()).toContain('language-zig')
  })

  it('renders code content with plaintext language when no language is given', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'code',
        args: { content: 'x = 1' },
      },
    })
    expect(wrapper.html()).toContain('language-plaintext')
  })

  it('renders image content as <img> with the data: URL', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'image',
        args: { content: 'data:image/png;base64,iVBORw0KGgo=' },
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe('data:image/png;base64,iVBORw0KGgo=')
  })

  it('renders image content as <img> with an http(s) URL', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'image',
        args: { content: 'https://example.com/cat.png' },
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe('https://example.com/cat.png')
  })

  it('renders html content inside a sandboxed iframe', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'html',
        args: { content: '<h1>Hi</h1>' },
      },
    })
    const iframe = wrapper.find('[data-testid="preview-html-iframe"]')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('sandbox')).toBe('allow-scripts')
  })

  it('paints the html frame canvas with the app surface, never a hardcoded white', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'html',
        args: { content: '<h1>Hi</h1>' },
      },
    })
    const srcdoc = wrapper.find('[data-testid="preview-html-iframe"]').attributes('srcdoc') ?? ''
    expect(srcdoc).not.toMatch(/background:\s*#fff/i)
    expect(srcdoc.toLowerCase()).toContain(`background:${FRAME_CANVAS_FALLBACK}`)
    const container = wrapper.find('[data-testid="preview-html-container"]')
    expect(container.classes().join(' ')).not.toContain('bg-white')
  })

  it('shows an "Open in new tab" button for html content', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'html',
        args: { content: '<h1>Hi</h1>' },
      },
    })
    expect(wrapper.find('[data-testid="preview-open-new-tab-button"]').exists()).toBe(true)
  })

  it('does not show the new-tab button for non-html content', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: '# Title' },
      },
    })
    expect(wrapper.find('[data-testid="preview-open-new-tab-button"]').exists()).toBe(false)
  })

  it('clicking "Open in new tab" calls window.open with a blob URL', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const createSpy = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:mock')
    const revokeSpy = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
    try {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>Hi</h1>' },
        },
      })
      await wrapper.find('[data-testid="preview-open-new-tab-button"]').trigger('click')
      expect(createSpy).toHaveBeenCalled()
      expect(openSpy).toHaveBeenCalledWith('blob:mock', '_blank', 'noopener')
    } finally {
      openSpy.mockRestore()
      createSpy.mockRestore()
      revokeSpy.mockRestore()
    }
  })

  it('renders title and caption when provided', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: '# Hi', title: 'My Title', caption: 'My caption' },
      },
    })
    expect(wrapper.html()).toContain('My Title')
    expect(wrapper.html()).toContain('My caption')
  })

  it('auto-resizes the iframe height on postMessage', async () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'html',
        args: { content: '<h1>Hi</h1>' },
      },
      attachTo: document.body,
    })
    const iframe = wrapper.find('[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
    window.dispatchEvent(
      new MessageEvent('message', {
        data: { source: 'show-preview-auto-resize', height: 500 },
      }),
    )
    await wrapper.vm.$nextTick()
    expect(iframe.style.height).toBe('500px')
    wrapper.unmount()
  })
})
