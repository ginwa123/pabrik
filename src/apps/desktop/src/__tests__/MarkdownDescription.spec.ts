/** Tests for MarkdownDescription — the display-only component used to render kanban task
 * descriptions. —
 * MarkdownDescription component (display only). */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import MarkdownDescription from '../components/kanban/MarkdownDescription.vue'

const PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='

describe('MarkdownDescription', () => {
  it('renders plain text as a paragraph', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'hello world' },
    })
    expect(wrapper.html()).toContain('<p>hello world</p>')
  })

  it('renders bold, italic, heading, list, and inline code', () => {
    const wrapper = mount(MarkdownDescription, {
      props: {
        source: [
          '**bold** and *italic*',
          '',
          '# Heading',
          '',
          '- item one',
          '- item two',
          '',
          '`inline code`',
        ].join('\n'),
      },
    })
    const html = wrapper.html()
    expect(html).toContain('<strong>bold</strong>')
    expect(html).toContain('<em>italic</em>')
    expect(html).toContain('<h1>Heading</h1>')
    expect(html).toContain('<li>item one</li>')
    expect(html).toContain('<code>inline code</code>')
  })

  it('wraps @/path/to/file.vue in a .md-file-chip span with data-file-path', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'see @/src/apps/desktop/src/components/file/FileInput.vue for details' },
    })
    const html = wrapper.html()
    expect(html).toMatch(/md-file-chip/)
    expect(html).toContain('data-file-path="/src/apps/desktop/src/components/file/FileInput.vue"')
  })

  it('does NOT match @token without a leading slash (e.g. @username)', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'ping @alice about the change' },
    })
    expect(wrapper.html()).not.toContain('md-file-chip')
  })

  it('does NOT match /path/without/at-prefix when wrapped in backticks', () => {
    // Backticks are the new opt-out (replacing the `@` requirement).
    // The path inside backticks renders as inline code, not a chip.
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'edit `/src/main.zig` to add the new route' },
    })
    expect(wrapper.html()).not.toContain('md-file-chip')
  })

  it('matches /path/without/at-prefix (no @ required anymore)', () => {
    // The new (rich editor) convention: file paths are just `/path`
    // — no `@` prefix. The legacy `@/path` form is also still
    // supported for backward compatibility (see other tests).
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'edit /src/main.zig to add the new route' },
    })
    expect(wrapper.html()).toContain('md-file-chip')
    expect(wrapper.html()).toContain('data-file-path="/src/main.zig"')
  })

  it('matches multiple @/path tokens in the same source', () => {
    const wrapper = mount(MarkdownDescription, {
      props: {
        source:
          'see @/src/a.ts and @/src/b/c.ts for context; also @/lib/util/d.ts',
      },
    })
    const html = wrapper.html()
    const matches = html.match(/md-file-chip/g) ?? []
    expect(matches.length).toBe(3)
    expect(html).toContain('data-file-path="/src/a.ts"')
    expect(html).toContain('data-file-path="/src/b/c.ts"')
    expect(html).toContain('data-file-path="/lib/util/d.ts"')
  })

  it('renders image data URLs as <img> elements with sensible sizing', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: `![alt text](${PNG_DATA_URL})` },
    })
    const html = wrapper.html()
    expect(html).toContain('<img')
    expect(html).toContain('src="' + PNG_DATA_URL + '"')
    expect(html).toContain('alt="alt text"')
  })

  it('applies maxHeight prop as inline style with overflow hidden', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'long text', maxHeight: '3rem' },
    })
    const html = wrapper.html()
    expect(html).toContain('max-height: 3rem')
    expect(html).toContain('overflow: hidden')
  })

  it('renders nothing for empty / null source (no <p></p> artifact)', () => {
    const wrapperEmpty = mount(MarkdownDescription, {
      props: { source: '' },
    })
    expect(wrapperEmpty.html()).not.toContain('<p></p>')

    const wrapperNull = mount(MarkdownDescription, {
      props: { source: null as unknown as string },
    })
    expect(wrapperNull.html()).not.toContain('<p></p>')
  })

  it('applies the testId prop as data-testid on the host element', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'hello', testId: 'my-md-block' },
    })
    expect(wrapper.html()).toContain('data-testid="my-md-block"')
  })

  it('defaults testId to "markdown-description"', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'hello' },
    })
    expect(wrapper.html()).toContain('data-testid="markdown-description"')
  })

  it('renders the host div with the markdown-content class for theme styling', () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'hello' },
    })
    expect(wrapper.html()).toContain('markdown-content')
  })

  it('emits file-click when a chip is clicked', async () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'see /CLAUDE.md for details' },
    })
    const chip = wrapper.find('.md-file-chip')
    expect(chip.exists()).toBe(true)
    await chip.trigger('click')
    expect(wrapper.emitted('file-click')).toBeTruthy()
    expect(wrapper.emitted('file-click')?.[0]?.[0]).toBe('/CLAUDE.md')
  })

  it('does NOT emit file-click when a non-chip element is clicked', async () => {
    const wrapper = mount(MarkdownDescription, {
      props: { source: 'plain text without any chip' },
    })
    await wrapper.find('.markdown-content').trigger('click')
    expect(wrapper.emitted('file-click')).toBeFalsy()
  })
})