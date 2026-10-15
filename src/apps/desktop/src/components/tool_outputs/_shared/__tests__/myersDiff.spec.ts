/** Tests for myersDiff.ts — Myers O(ND) line/word diff + renderers. Critical: the position-based
 * `isLineChanged = (idx) => beforeLines[idx] !== afterLines[idx]` (the OLD broken approach this
 * replaces) treated every line after an insertion as "changed" because indices shifted. */

/** Tests here verify the new algorithm does NOT have that bug — a line shift at position N must NOT
 * mark line N+1 as changed. */
import { describe, expect, it } from 'vitest'
import {
  computeInlineWordChanges,
  computeSplitView,
  computeUnifiedView,
  myersDiff,
  splitLines,
} from '../myersDiff'

describe('splitLines', () => {
  it('returns empty for empty input', () => {
    expect(splitLines('')).toEqual([])
  })

  it('splits on \\n and preserves line content', () => {
    expect(splitLines('a\nb\nc')).toEqual(['a', 'b', 'c'])
  })

  it('strips a trailing empty caused by terminal \\n', () => {
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
  })

  it('keeps a leading empty if the string starts with \\n', () => {
    expect(splitLines('\na\nb')).toEqual(['', 'a', 'b'])
  })
})

describe('myersDiff', () => {
  it('returns [] when both sides are empty', () => {
    expect(myersDiff([], [])).toEqual([])
  })

  it('returns only inserts when before is empty', () => {
    const ops = myersDiff([], ['a', 'b'])
    expect(ops).toHaveLength(2)
    expect(ops.every((o) => o.type === 'insert')).toBe(true)
    expect(ops[0]?.afterLine).toBe(1)
    expect(ops[1]?.afterLine).toBe(2)
  })

  it('returns only deletes when after is empty', () => {
    const ops = myersDiff(['a', 'b'], [])
    expect(ops).toHaveLength(2)
    expect(ops.every((o) => o.type === 'delete')).toBe(true)
    expect(ops[0]?.beforeLine).toBe(1)
    expect(ops[1]?.beforeLine).toBe(2)
  })

  it('returns only equals for identical inputs', () => {
    const ops = myersDiff(['a', 'b', 'c'], ['a', 'b', 'c'])
    expect(ops).toHaveLength(3)
    expect(ops.every((o) => o.type === 'equal')).toBe(true)
  })

  it('single insert at the end', () => {
    const ops = myersDiff(['a', 'b'], ['a', 'b', 'c'])
    expect(ops.filter((o) => o.type === 'equal')).toHaveLength(2)
    expect(ops[ops.length - 1]).toMatchObject({
      type: 'insert',
      afterLine: 3,
      text: 'c',
    })
  })

  it('single insert at the beginning', () => {
    const ops = myersDiff(['b', 'c'], ['a', 'b', 'c'])
    expect(ops).toHaveLength(3)
    expect(ops[0]).toMatchObject({ type: 'insert', afterLine: 1, text: 'a' })
  })

  it('single insert in the middle', () => {
    const ops = myersDiff(['a', 'c'], ['a', 'b', 'c'])
    expect(ops).toHaveLength(3)
    expect(ops[0]).toMatchObject({ type: 'equal', text: 'a' })
    expect(ops[1]).toMatchObject({ type: 'insert', text: 'b' })
    expect(ops[2]).toMatchObject({ type: 'equal', text: 'c' })
  })

  it('REGRESSION: line shift after insert does NOT mark later lines as changed', () => {
    // The old broken `isLineChanged = (idx) => beforeLines[idx] !== afterLines[idx]`
    // would mark both the new "b" AND all lines after it as "changed". Myers
    // marks only "b" as insert and leaves the trailing lines as equals.
    const ops = myersDiff(['a', 'c', 'd', 'e'], ['a', 'b', 'c', 'd', 'e'])
    const insertOrDeleteCount = ops.filter(
      (o) => o.type === 'insert' || o.type === 'delete',
    ).length
    expect(insertOrDeleteCount).toBe(1)
    // The trailing 3 lines (c, d, e) must all be 'equal'
    const trailing = ops.filter(
      (o) => o.type === 'equal' && o.text !== 'a',
    )
    expect(trailing).toHaveLength(3)
    expect(trailing.map((o) => o.text)).toEqual(['c', 'd', 'e'])
  })

  it('REGRESSION: line shift after delete does NOT mark later lines as changed', () => {
    const ops = myersDiff(['a', 'b', 'c', 'd', 'e'], ['a', 'c', 'd', 'e'])
    const changedCount = ops.filter((o) => o.type !== 'equal').length
    expect(changedCount).toBe(1)
    expect(ops.filter((o) => o.type === 'equal').map((o) => o.text)).toEqual([
      'a',
      'c',
      'd',
      'e',
    ])
  })

  it('multi-hunk: two independent changes separated by stable context', () => {
    const before = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']
    const after = ['1', '2', '3-X', '4', '5', '6', '7', '8', '9-Y', '10']
    const ops = myersDiff(before, after)
    // The changed ops include both delete ('3', '9') and insert ('3-X', '9-Y').
    const changed = ops.filter((o) => o.type !== 'equal')
    expect(changed).toHaveLength(4)
    expect(changed.map((o) => `${o.type}:${o.text}`).sort()).toEqual([
      'delete:3',
      'delete:9',
      'insert:3-X',
      'insert:9-Y',
    ])
  })

  it('UTF-8 multi-byte content survives intact', () => {
    const ops = myersDiff(['héllo', 'wörld'], ['héllo', 'wörld', '✨'])
    const equalTexts = ops.filter((o) => o.type === 'equal').map((o) => o.text)
    expect(equalTexts).toContain('héllo')
    expect(equalTexts).toContain('wörld')
    const inserted = ops.find((o) => o.type === 'insert')
    expect(inserted?.text).toBe('✨')
  })

  it('very long lines do not blow up', () => {
    // We compare at line granularity — each line is atomic. Two single-line inputs where one line
    // is a strict prefix of the other: LCS length is 0 (they're different lines), so SES is "delete
    // + insert".

    // This verifies the algorithm completes in finite time on 10k-char lines without pathological
    // behaviour.
    const longBefore = 'x'.repeat(10_000)
    const longAfter = 'x'.repeat(10_000) + 'tail'
    const ops = myersDiff([longBefore], [longAfter])
    expect(ops).toHaveLength(2)
    expect(ops[0]?.type).toBe('delete')
    expect(ops[0]?.text.length).toBe(10_000)
    expect(ops[1]?.type).toBe('insert')
    expect(ops[1]?.text.length).toBe(10_004)
  })

  it('long identical lines do not blow up', () => {
    // When two 10k-char lines are identical, LCS finds it.
    const longLine = 'x'.repeat(10_000)
    const ops = myersDiff([longLine], [longLine])
    expect(ops).toHaveLength(1)
    expect(ops[0]?.type).toBe('equal')
    expect(ops[0]?.text.length).toBe(10_000)
  })

  it('line numbers are stable across the SES', () => {
    // Verify beforeLine/afterLine stay monotonic across equal stretches.
    const ops = myersDiff(['a', 'b', 'c', 'd', 'e'], ['a', 'b', 'X', 'd', 'e'])
    const equals = ops.filter((o) => o.type === 'equal')
    const beforeLines = equals.map((o) => o.beforeLine)
    const afterLines = equals.map((o) => o.afterLine)
    // Strictly increasing (1, 2, 4, 5) — note the gap from the deleted 'c'
    expect(beforeLines).toEqual([1, 2, 4, 5])
    expect(afterLines).toEqual([1, 2, 4, 5])
  })
})

describe('computeInlineWordChanges', () => {
  it('returns equal-only changes for identical lines (no inserts/deletes)', () => {
    // 'hello world' tokenizes to ['hello', ' ', 'world'] — 3 tokens, all equal.
    const changes = computeInlineWordChanges('hello world', 'hello world')
    expect(changes.filter((c) => c.type === 'equal')).toHaveLength(3)
    expect(changes.filter((c) => c.type !== 'equal')).toHaveLength(0)
  })

  it('shows inserts for new words', () => {
    const changes = computeInlineWordChanges('foo bar', 'foo baz bar')
    const inserts = changes.filter((c) => c.type === 'insert')
    expect(inserts.length).toBeGreaterThan(0)
    expect(inserts.map((c) => c.text).join('')).toContain('baz')
  })

  it('shows deletes for removed words', () => {
    const changes = computeInlineWordChanges('foo baz bar', 'foo bar')
    const deletes = changes.filter((c) => c.type === 'delete')
    expect(deletes.length).toBeGreaterThan(0)
    expect(deletes.map((c) => c.text).join('')).toContain('baz')
  })

  it('handles pure-delete (empty after)', () => {
    const changes = computeInlineWordChanges('hello', '')
    expect(changes.every((c) => c.type === 'delete')).toBe(true)
  })

  it('handles pure-insert (empty before)', () => {
    const changes = computeInlineWordChanges('', 'hello')
    expect(changes.every((c) => c.type === 'insert')).toBe(true)
    expect(changes.map((c) => c.text).join('')).toBe('hello')
  })
})

describe('computeSplitView', () => {
  it('REGRESSION: split view keeps unchanged lines flagged as isChanged=false', () => {
    // Insert at line 2 of a 10-line file. Lines 3-10 must still be isChanged=false.
    const before = ['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10']
    const after = ['l1', 'l2', 'INSERTED', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10']
    const rows = computeSplitView(before, after)
    const unchangedRows = rows.filter((r) => !r.isChanged)
    expect(unchangedRows).toHaveLength(10)
    expect(unchangedRows.every((r) => r.beforeText === r.afterText)).toBe(true)
  })

  it('paired delete+insert share the same row block (visual alignment)', () => {
    const before = ['foo bar', 'baz']
    const after = ['foo qux', 'baz']
    const rows = computeSplitView(before, after)
    // Expect: row1=equal(foo bar / foo qux with delete+insert word inline);
    // row2=equal(baz). The renderer walks adjacent delete/insert to "align"
    // them visually.
    const equalCount = rows.filter((r) => !r.isChanged).length
    expect(equalCount).toBe(1)
  })
})

describe('computeUnifiedView', () => {
  it('emits a hunk header for any non-empty change', () => {
    const rows = computeUnifiedView(['a'], ['a', 'b'])
    const hunks = rows.filter((r) => r.kind === 'hunk')
    expect(hunks.length).toBe(1)
    expect(hunks[0]?.text).toMatch(/^@@ -\d+,\d+ \+\d+,\d+ @@$/)
  })

  it('emits +/- prefix on changed lines', () => {
    const rows = computeUnifiedView(['a', 'b'], ['a', 'B'])
    const inserts = rows.filter((r) => r.kind === 'insert')
    const deletes = rows.filter((r) => r.kind === 'delete')
    expect(inserts.length).toBeGreaterThan(0)
    expect(deletes.length).toBeGreaterThan(0)
    expect(inserts[0]?.text.startsWith('+')).toBe(true)
    expect(deletes[0]?.text.startsWith('-')).toBe(true)
  })

  it('context lines are spaced (prefix " ")', () => {
    const before = ['ctx1', 'ctx2', 'old', 'ctx3', 'ctx4']
    const after = ['ctx1', 'ctx2', 'NEW', 'ctx3', 'ctx4']
    const rows = computeUnifiedView(before, after)
    const context = rows.filter((r) => r.kind === 'context')
    expect(context.length).toBeGreaterThan(0)
    expect(context.every((r) => r.text.startsWith(' '))).toBe(true)
  })
})