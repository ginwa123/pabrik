/** A finished reply must never lose the text after an element or comment the model left open: the
 * parser reads on to the matching end tag — or to the end of the message — and paints none of it. */
import { describe, it, expect, beforeEach } from 'vitest'
import { renderResponse, renderMarkdown, _resetRenderResponseCache } from '../renderResponse'

// The swallowed tail is still in the DOM as these elements' text, so a raw textContent read would
// pass with the fix removed; drop them first so the assertion covers what actually paints.
const NEVER_DISPLAYED = 'style,script,title,textarea,xmp,noscript'

const visibleText = (html: string): string => {
  const host = document.createElement('div')
  host.innerHTML = html
  host.querySelectorAll(NEVER_DISPLAYED).forEach((node) => node.remove())
  return host.textContent ?? ''
}

const TAIL = 'the tail the user could not reach'

describe('a finished reply keeps the text after an element the model left open', () => {
  beforeEach(() => _resetRenderResponseCache())

  it('keeps the tail when a truncated <html> report stops inside its <style>', () => {
    const content = [
      'Here is the audit.',
      '',
      '<html>',
      '<style>',
      '.card{color:#c5c9c5}',
      `.row{margin:0}`,
      '',
      'Card in review. Nothing pushed.',
      TAIL,
    ].join('\n')

    expect(visibleText(renderResponse(content, 'assistant'))).toContain(TAIL)
  })

  it('keeps the tail when an HTML comment is never closed', () => {
    const content = `Here is the audit.\n\n<!-- still writing\n\n${TAIL}`
    expect(visibleText(renderResponse(content, 'assistant'))).toContain(TAIL)
  })

  it('keeps the tail when a <textarea> is never closed', () => {
    const content = `Here is the audit.\n\n<textarea>${TAIL}`
    expect(visibleText(renderResponse(content, 'assistant'))).toContain(TAIL)
  })

  it('keeps the tail when a <script> is never closed', () => {
    const content = `Here is the audit.\n\n<script>var rows = 1;\n\n${TAIL}`
    expect(visibleText(renderResponse(content, 'assistant'))).toContain(TAIL)
  })

  it('keeps the tail in a markdown segment that sits beside a closed <html> block', () => {
    const content = `Report below.\n\n<style>.unclosed{color:red}\n\n${TAIL}`
    expect(visibleText(renderMarkdown(content))).toContain(TAIL)
  })
})

describe('a closed element still renders as itself', () => {
  beforeEach(() => _resetRenderResponseCache())

  it('keeps a closed <style> a style element so a report keeps its look', () => {
    const html = renderResponse('Intro.\n\n<style>.card{color:red}</style>\n\nDone.', 'assistant')
    expect(html).toContain('<style>')
    expect(visibleText(html)).toContain('Done.')
  })

  it('leaves a code span that only mentions the tag alone', () => {
    const html = renderResponse('The `<style>` tag is raw text.', 'assistant')
    expect(visibleText(html)).toContain('<style>')
  })
})
