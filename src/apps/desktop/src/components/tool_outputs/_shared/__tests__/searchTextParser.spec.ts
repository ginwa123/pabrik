import { describe, expect, it } from 'vitest'
import { parseSearch } from '../toolOutputParser'

/** `parseSearch` against the tool's DEFAULT output format: `rg -n` text bytes arrive as `_raw`,
 *  which the card used to render as "0 files, 0 matches". */
describe("parseSearch — the tool's default text payload", () => {
  it('reads the default text payload: path:line:text rows become file results', () => {
    const r = parseSearch({ _raw: '/a.ts:10:hello\n/a.ts:20:again\n/b.ts:5:world' })
    expect(r.fileResults.map((f) => f.path)).toEqual(['/a.ts', '/b.ts'])
    expect(r.fileResults[0]?.count).toBe(2)
    expect(r.fileResults[0]?.total).toBe(2)
    expect(r.fileResults[0]?.matches).toEqual([
      { lineNumber: 10, snippet: 'hello' },
      { lineNumber: 20, snippet: 'again' },
    ])
  })
  it('keeps a Windows drive letter inside the path, not in the line number', () => {
    const r = parseSearch({ _raw: 'C:\\repo\\a.ts:7:hit' })
    expect(r.fileResults[0]?.path).toBe('C:\\repo\\a.ts')
    expect(r.fileResults[0]?.matches[0]).toEqual({ lineNumber: 7, snippet: 'hit' })
  })
  it('reads count_only rows as a per-file count', () => {
    const r = parseSearch({ _raw: '/a.ts:3\n/b.ts:1' })
    expect(r.fileResults).toEqual([
      { path: '/a.ts', total: 3, count: 3, matches: [] },
      { path: '/b.ts', total: 1, count: 1, matches: [] },
    ])
  })
  it('keeps a context row visible without counting it as a match', () => {
    const r = parseSearch({ _raw: '/a.ts:10:hit\n/a.ts-11-before\n/a.ts-12-before' })
    expect(r.fileResults[0]?.count).toBe(1)
    expect(r.fileResults[0]?.matches).toHaveLength(3)
  })
  it('turns the truncation note into the returned/total summary', () => {
    const r = parseSearch({
      _raw: '/a.ts:1:hit\n[truncated: showing 1 of 40 matches — raise max_results]',
    })
    expect(r.returned).toBe(1)
    expect(r.total).toBe(40)
    expect(r.truncated).toBe(true)
    expect(r.truncatedHint).toContain('showing 1 of 40')
  })
  it('carries the text warning through when nothing matched', () => {
    const r = parseSearch({
      _raw: '<warning>no matches for pattern "zzz" in path "/repo"</warning>',
    })
    expect(r.warning).toContain('no matches for pattern')
    expect(r.fileResults).toEqual([])
  })
})
