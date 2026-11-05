import { describe, it, expect } from 'vitest'
import { extractRichBlocks, hasRichBlocks } from '../richBlocks'

const MERMAID_SOURCE = 'flowchart TD\n  A[Prompt] --> B[Diagram]'
const PLANTUML_SOURCE = '@startuml\nAlice -> Bob: hello\n@enduml'
const D2_SOURCE = 'a: Alpha -> b: Beta'

describe('hasRichBlocks', () => {
  it('is false for absent, empty and plain markdown content', () => {
    expect(hasRichBlocks(undefined)).toBe(false)
    expect(hasRichBlocks('')).toBe(false)
    expect(hasRichBlocks('# Heading\n\nSome **bold** text.')).toBe(false)
  })

  it('recognises a closed <html> block, tag case-insensitively', () => {
    expect(hasRichBlocks('<html><b>x</b></html>')).toBe(true)
    expect(hasRichBlocks('prose\n<HTML><b>x</b></HTML>')).toBe(true)
  })

  it('recognises a closed <mermaid> block and a ```mermaid fence', () => {
    expect(hasRichBlocks(`<mermaid>${MERMAID_SOURCE}</mermaid>`)).toBe(true)
    expect(hasRichBlocks('```mermaid\n' + MERMAID_SOURCE + '\n```')).toBe(true)
  })

  it('recognises a closed <plantuml> block and a ```plantuml fence', () => {
    expect(hasRichBlocks(`<plantuml>${PLANTUML_SOURCE}</plantuml>`)).toBe(true)
    expect(hasRichBlocks('```plantuml\n' + PLANTUML_SOURCE + '\n```')).toBe(true)
    expect(hasRichBlocks('<plantuml>@startuml\nA -> B')).toBe(false)
  })

  it('recognises a closed <d2> block and a ```d2 fence', () => {
    expect(hasRichBlocks(`<d2>${D2_SOURCE}</d2>`)).toBe(true)
    expect(hasRichBlocks('```d2\n' + D2_SOURCE + '\n```')).toBe(true)
    expect(hasRichBlocks('<d2>a -> b')).toBe(false)
  })

  it('is false for a tag whose closing half has not streamed in yet', () => {
    // Mid-stream the payload must fall through to the legacy markdown path,
    // not render a half-built frame.
    expect(hasRichBlocks('<html><div>never closed')).toBe(false)
    expect(hasRichBlocks('<mermaid>flowchart TD\n  A --> B')).toBe(false)
  })

  it('is stateless across calls (a repeated call cannot drift)', () => {
    const content = `<mermaid>${MERMAID_SOURCE}</mermaid>`
    expect(hasRichBlocks(content)).toBe(true)
    expect(hasRichBlocks(content)).toBe(true)
    expect(hasRichBlocks('plain prose')).toBe(false)
  })
})

describe('extractRichBlocks', () => {
  it('returns one markdown segment for content with no block', () => {
    expect(extractRichBlocks('  # Heading  ')).toEqual([{ kind: 'markdown', payload: '# Heading' }])
  })

  it('never returns an empty array — blank content yields one empty markdown segment', () => {
    expect(extractRichBlocks('   ')).toEqual([{ kind: 'markdown', payload: '' }])
  })

  it('splits prose around a mermaid block, in document order', () => {
    expect(
      extractRichBlocks(`Here is the flow:\n<mermaid>${MERMAID_SOURCE}</mermaid>\nDone.`),
    ).toEqual([
      { kind: 'markdown', payload: 'Here is the flow:' },
      { kind: 'mermaid', payload: MERMAID_SOURCE },
      { kind: 'markdown', payload: 'Done.' },
    ])
  })

  it('carries the html payload without its tags', () => {
    expect(extractRichBlocks('<html><b>live</b></html>')).toEqual([
      { kind: 'html', payload: '<b>live</b>' },
    ])
  })

  it('gives each block of a mixed turn its own segment', () => {
    const content = `<html><b>widget</b></html>\n<mermaid>${MERMAID_SOURCE}</mermaid>`
    expect(extractRichBlocks(content)).toEqual([
      { kind: 'html', payload: '<b>widget</b>' },
      { kind: 'mermaid', payload: MERMAID_SOURCE },
    ])
  })

  it('takes a ```mermaid fence as a mermaid block, without the fence lines', () => {
    expect(extractRichBlocks('```mermaid\n' + MERMAID_SOURCE + '\n```')).toEqual([
      { kind: 'mermaid', payload: MERMAID_SOURCE },
    ])
  })

  it('takes a <plantuml> block and a ```plantuml fence as plantuml segments', () => {
    expect(extractRichBlocks(`<plantuml>${PLANTUML_SOURCE}</plantuml>`)).toEqual([
      { kind: 'plantuml', payload: PLANTUML_SOURCE },
    ])
    expect(extractRichBlocks('```plantuml\n' + PLANTUML_SOURCE + '\n```')).toEqual([
      { kind: 'plantuml', payload: PLANTUML_SOURCE },
    ])
  })

  it('does not read a plantuml fence as a mermaid one, or the reverse', () => {
    const content =
      '<plantuml>' + PLANTUML_SOURCE + '</plantuml>\n```mermaid\n' + MERMAID_SOURCE + '\n```'
    expect(extractRichBlocks(content)).toEqual([
      { kind: 'plantuml', payload: PLANTUML_SOURCE },
      { kind: 'mermaid', payload: MERMAID_SOURCE },
    ])
  })

  it('takes a <d2> block and a ```d2 fence as d2 segments', () => {
    expect(extractRichBlocks(`<d2>${D2_SOURCE}</d2>`)).toEqual([{ kind: 'd2', payload: D2_SOURCE }])
    expect(extractRichBlocks('```d2\n' + D2_SOURCE + '\n```')).toEqual([
      { kind: 'd2', payload: D2_SOURCE },
    ])
  })

  it('keeps a trailing unterminated block as prose', () => {
    // Regression guard for streaming: `hasRichBlocks` is false here, but the
    // splitter must still not swallow the text.
    expect(extractRichBlocks('prose <mermaid>flowchart TD\n  A --> B')).toEqual([
      { kind: 'markdown', payload: 'prose <mermaid>flowchart TD\n  A --> B' },
    ])
  })

  it('reads a block whose opening tag carries attributes', () => {
    // A model writing a real document emits `<html lang="en">`, not a bare tag. A
    // bare-tag-only pattern dropped the whole block into the markdown path, so the
    // user saw escaped source instead of a rendered surface.
    expect(extractRichBlocks('<html lang="en"><b>live</b></html>')).toEqual([
      { kind: 'html', payload: '<b>live</b>' },
    ])
    expect(extractRichBlocks('<mermaid class="wide">' + MERMAID_SOURCE + '</mermaid>')).toEqual([
      { kind: 'mermaid', payload: MERMAID_SOURCE },
    ])
    expect(hasRichBlocks('<html data-theme="dark"><b>x</b></html>')).toBe(true)
  })

  it('does not read a longer tag name as one of the wrappers', () => {
    // `<htmlfoo>` is not `<html>`; the attribute form must not loosen the tag match.
    expect(hasRichBlocks('<htmlish><b>x</b></htmlish>')).toBe(false)
    expect(hasRichBlocks('<d2x>a -> b</d2x>')).toBe(false)
  })

  it("carries an interactive widget's markup and script into the payload untouched", () => {
    // The frame runs this payload as a live document, so the splitter must not
    // reorder, escape or drop the handlers and the form.
    const widget =
      '<label>Name</label><input id="n" oninput="render()">' +
      '<form onsubmit="event.preventDefault(); render()"><button type="submit">Go</button></form>' +
      '<p id="out"></p><script>function render(){document.getElementById("out").textContent="hi"}</script>'
    expect(extractRichBlocks(`<html>${widget}</html>`)).toEqual([{ kind: 'html', payload: widget }])
  })

  it('lays out a mixed plan turn — prose, html, mermaid, prose — in document order', () => {
    const content =
      'Here is the plan:\n' +
      '<html><h2>Steps</h2><input id="q"></html>\n' +
      'and the flow it follows:\n' +
      `<mermaid>${MERMAID_SOURCE}</mermaid>\n` +
      'Start with step 1.'
    expect(extractRichBlocks(content)).toEqual([
      { kind: 'markdown', payload: 'Here is the plan:' },
      { kind: 'html', payload: '<h2>Steps</h2><input id="q">' },
      { kind: 'markdown', payload: 'and the flow it follows:' },
      { kind: 'mermaid', payload: MERMAID_SOURCE },
      { kind: 'markdown', payload: 'Start with step 1.' },
    ])
  })
})
