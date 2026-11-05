import { describe, it, expect } from 'vitest'
import { buildHtmlSrcdoc } from '../helpers/chatHtmlFrame'

const WIDGET =
  '<form onsubmit="event.preventDefault(); go()"><input id="q" value="7">' +
  '<button type="submit">Go</button></form><p id="out"></p>' +
  '<script>function go(){document.getElementById("out").textContent="ok"}</script>'

describe('buildHtmlSrcdoc — an interactive <html> block', () => {
  it('carries the widget markup, handlers and script into the frame document untouched', () => {
    const srcdoc = buildHtmlSrcdoc(WIDGET)
    expect(srcdoc).toContain('<form onsubmit="event.preventDefault(); go()">')
    expect(srcdoc).toContain('<input id="q" value="7">')
    expect(srcdoc).toContain('function go(){')
  })

  it('keeps the resize reporter so a widget that grows re-measures itself', () => {
    expect(buildHtmlSrcdoc(WIDGET)).toContain('chat-html-frame-auto-resize')
  })

  it('passes a full interactive document through instead of nesting it in a second <html>', () => {
    const page =
      '<!DOCTYPE html><html lang="en"><body><input id="a">' +
      '<script>document.getElementById("a").focus()</script></body></html>'
    const srcdoc = buildHtmlSrcdoc(page)
    expect(srcdoc.match(/<html/gi)).toHaveLength(1)
    expect(srcdoc).toContain('<input id="a">')
    expect(srcdoc).toContain('document.getElementById("a").focus()')
  })
})
