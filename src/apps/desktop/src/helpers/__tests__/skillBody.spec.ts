/** skillBody.ts — the outline and the find box over one skill's body, as
 * pure functions over the raw markdown the detail pane already holds. */
import { describe, expect, it } from 'vitest'
import { countBodyMatches, extractSections, findInBody } from '../skillBody'

const BODY = [
  '---',
  'name: my-skill',
  '---',
  '',
  '## When to Use',
  '',
  'Load this when the task is about tests.',
  '',
  '## Procedure',
  '',
  '### Write the test first',
  '',
  'Run `zig build test`.',
  '',
  '```md',
  '## Not a section',
  '```',
  '',
  '## Pitfalls',
  '',
  'A flaky test is a hidden input.',
  '',
].join('\n')

describe('the outline', () => {
  it('lists the ## and ### headings in document order', () => {
    expect(extractSections(BODY)).toEqual([
      { title: 'When to Use', line: 5, depth: 2 },
      { title: 'Procedure', line: 9, depth: 2 },
      { title: 'Write the test first', line: 11, depth: 3 },
      { title: 'Pitfalls', line: 19, depth: 2 },
    ])
  })

  it('reports 1-based line numbers, so a jump can target them', () => {
    const sections = extractSections(BODY)
    // Line 5 of the body is the "## When to Use" line.
    expect(BODY.split('\n')[sections[0].line - 1]).toBe('## When to Use')
  })

  it('ignores a heading inside a fenced code block', () => {
    const titles = extractSections(BODY).map((s) => s.title)
    expect(titles).not.toContain('Not a section')
  })

  it('strips the closing hashes from a closed ATX heading', () => {
    expect(extractSections('## Procedure ##')[0].title).toBe('Procedure')
  })

  it('ignores a level-1 heading, which is the frontmatter title', () => {
    expect(extractSections('# My Skill\n\n## Procedure')).toHaveLength(1)
  })

  it('ignores a heading with no text', () => {
    expect(extractSections('##\n##   \n## Real')).toEqual([{ title: 'Real', line: 3, depth: 2 }])
  })

  it('returns nothing for a body with no headings', () => {
    expect(extractSections('just prose\nand more prose')).toEqual([])
  })

  it('returns nothing for an empty body', () => {
    expect(extractSections('')).toEqual([])
  })
})

describe('finding text in the body', () => {
  it('returns every line containing the term, case-insensitively', () => {
    const hits = findInBody(BODY, 'TEST')
    // Lines 7, 11, 13 and 21 of the fixture body.
    expect(hits.map((h) => h.line)).toEqual([7, 11, 13, 21])
  })

  it('trims the line it reports', () => {
    const hits = findInBody(BODY, 'flaky')
    expect(hits[0].text).toBe('A flaky test is a hidden input.')
  })

  it('matches nothing for an empty term, rather than everything', () => {
    expect(findInBody(BODY, '')).toEqual([])
    expect(findInBody(BODY, '   ')).toEqual([])
  })

  it('matches nothing for a term that is absent', () => {
    expect(findInBody(BODY, 'kubernetes')).toEqual([])
  })

  it('reports the line a hit is on, so the pane can scroll to it', () => {
    const hits = findInBody(BODY, 'zig build test')
    expect(hits).toHaveLength(1)
    expect(BODY.split('\n')[hits[0].line - 1]).toContain('zig build test')
  })
})

describe('counting matches', () => {
  it('counts every occurrence, including two on one line', () => {
    expect(countBodyMatches('test and test again', 'test')).toBe(2)
  })

  it('is zero for an empty term', () => {
    expect(countBodyMatches(BODY, '')).toBe(0)
  })

  it('agrees with the number of lines that have at least one hit', () => {
    // One hit per line in this body, so the two counts must match.
    expect(countBodyMatches(BODY, 'test')).toBe(findInBody(BODY, 'test').length)
  })
})
