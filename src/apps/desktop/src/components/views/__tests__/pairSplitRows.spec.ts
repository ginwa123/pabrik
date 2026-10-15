/** `pairSplitRows` — the split (side-by-side) projection of a parsed unified
 * diff. The interesting cases are the UNEVEN change blocks (3 removals, 2
 * insertions) and the hunk boundaries, because those are where a naive
 * "render both sides by index" produces a row that silently shifts every
 * following line number. */
import { describe, expect, it } from 'vitest'
import { pairSplitRows, splitRowIndexBySourceIndex } from '../chat_right_sidebar/pairSplitRows'
import { parseUnifiedDiff } from '../chat_right_sidebar/parseUnifiedDiff'

/** Parse a one-file unified diff into split rows, the way the component does. */
function rows(diff: string) {
  return pairSplitRows(parseUnifiedDiff(diff).lines)
}

const MODIFY = [
  'diff --git a/x.go b/x.go',
  'index 111..222 100644',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -760,7 +760,7 @@ func Preview() {',
  ' \tchildren := make([]Child, len(dto.Children))',
  ' \tcopy(children, dto.Children)',
  ' ',
  '-\tsort.Slice(children, func(i, j int) bool {',
  '+\tsort.SliceStable(children, func(i, j int) bool {',
  ' \t\treturn children[i].Sequence < children[j].Sequence',
  ' \t})',
  '',
].join('\n')

describe('pairSplitRows — changes', () => {
  it('pairs a single removal with a single insertion on ONE row, each side keeping its own number', () => {
    const out = rows(MODIFY)
    const changed = out.filter((r) => r.isChanged)
    expect(changed).toHaveLength(1)
    expect(changed[0]!.oldLineNum).toBe(763)
    expect(changed[0]!.newLineNum).toBe(763)
    expect(changed[0]!.oldText).toBe('\tsort.Slice(children, func(i, j int) bool {')
    expect(changed[0]!.newText).toBe('\tsort.SliceStable(children, func(i, j int) bool {')
  })

  it('renders context on BOTH sides — the two gutters are independently readable', () => {
    const out = rows(MODIFY)
    const context = out.filter((r) => r.kind === 'context')
    // 4 context lines: 760, 761, (blank 762), 764, 765 → the trailing blank
    // line after the hunk is emitter noise, not a source line.
    expect(context.map((r) => r.oldLineNum)).toContain(760)
    expect(context.map((r) => r.newLineNum)).toContain(760)
    for (const row of context) {
      expect(row.oldText).toBe(row.newText)
      expect(row.isChanged).toBe(false)
    }
  })

  it('gives the longer side of an uneven change block a FILLER, never a shifted line', () => {
    // 3 removals, 2 insertions — the exact shape in the split-bill helper.
    const diff = [
      'diff --git a/s.go b/s.go',
      '--- a/s.go',
      '+++ b/s.go',
      '@@ -24,9 +24,8 @@ type splitBillPlan struct {',
      ' \tIsBalanced        bool',
      '-\tUnallocatedItems  []uuid.UUID',
      '-\tMissingSalesOrders []uuid.UUID',
      '-\tHasTaxOverride    bool',
      '+\tUnallocatedItems  []uuid.UUID',
      '+\tMissingSalesOrders []uuid.UUID',
      ' }',
      '',
    ].join('\n')
    const changed = rows(diff).filter((r) => r.isChanged)
    expect(changed).toHaveLength(3)
    // `IsBalanced` consumes old/new 24, so the removals are 25/26/27 and the
    // insertions 25/26 — index-wise pairing leaves old 27 with a filler.
    expect(changed.map((r) => [r.oldLineNum, r.newLineNum])).toEqual([
      [25, 25],
      [26, 26],
      [27, null],
    ])
    expect(changed[2]!.newText).toBeNull()
    expect(changed[2]!.oldText).toBe('\tHasTaxOverride    bool')
    // The following context row keeps ITS number — the filler must not consume
    // a line number on the new side.
    const after = rows(diff).find((r) => r.kind === 'context' && r.oldLineNum === 28)
    expect(after?.newLineNum).toBe(27)
  })

  it('handles a pure insertion (no old side) and a pure deletion (no new side)', () => {
    const insert = rows(
      [
        'diff --git a/i.go b/i.go',
        '--- a/i.go',
        '+++ b/i.go',
        '@@ -1,1 +1,2 @@',
        ' keep',
        '+added',
        '',
      ].join('\n'),
    ).filter((r) => r.isChanged)
    expect(insert).toHaveLength(1)
    expect(insert[0]!.oldText).toBeNull()
    expect(insert[0]!.oldLineNum).toBeNull()
    expect(insert[0]!.newLineNum).toBe(2)

    const del = rows(
      [
        'diff --git a/d.go b/d.go',
        '--- a/d.go',
        '+++ b/d.go',
        '@@ -1,2 +1,1 @@',
        '-gone',
        ' keep',
        '',
      ].join('\n'),
    ).filter((r) => r.isChanged)
    expect(del).toHaveLength(1)
    expect(del[0]!.newText).toBeNull()
    expect(del[0]!.newLineNum).toBeNull()
    expect(del[0]!.oldLineNum).toBe(1)
  })

  it('does not let a change block leak across a hunk boundary', () => {
    const diff = [
      'diff --git a/t.go b/t.go',
      '--- a/t.go',
      '+++ b/t.go',
      '@@ -1,1 +1,1 @@',
      '-one',
      '+ONE',
      '@@ -50,1 +50,1 @@',
      '-two',
      '+TWO',
      '',
    ].join('\n')
    const out = rows(diff)
    expect(out.filter((r) => r.kind === 'hunk')).toHaveLength(2)
    expect(out.filter((r) => r.isChanged).map((r) => [r.oldLineNum, r.newLineNum])).toEqual([
      [1, 1],
      [50, 50],
    ])
  })
})

describe('pairSplitRows — shape', () => {
  it('renders the hunk header as a full-width row', () => {
    const hunk = rows(MODIFY).find((r) => r.kind === 'hunk')
    expect(hunk).toBeDefined()
    expect(hunk!.oldText).toBeNull()
    expect(hunk!.newText).toBeNull()
    expect(hunk!.oldLineNum).toBeNull()
    expect(hunk!.newLineNum).toBeNull()
    expect(hunk!.sourceIndexes).toHaveLength(1)
  })

  it('renders an empty line inside a hunk on both sides', () => {
    const out = rows(MODIFY)
    const blank = out.find((r) => r.kind === 'context' && r.oldText === '')
    expect(blank).toBeDefined()
    expect(blank!.newText).toBe('')
  })

  it('carries the source indexes so review threads can be anchored', () => {
    const parsed = parseUnifiedDiff(MODIFY)
    const out = pairSplitRows(parsed.lines)
    const changed = out.find((r) => r.isChanged)!
    const removeIndex = parsed.lines.findIndex((l) => l.type === 'remove')
    const addIndex = parsed.lines.findIndex((l) => l.type === 'add')
    expect(changed.sourceIndexes).toEqual([removeIndex, addIndex])

    const bySource = splitRowIndexBySourceIndex(out)
    expect(bySource.get(removeIndex)).toBe(out.indexOf(changed))
    expect(bySource.get(addIndex)).toBe(out.indexOf(changed))
    // Every source line lands in exactly one row.
    expect(bySource.size).toBe(parsed.lines.length)
  })

  it('never mutates or reorders the input lines', () => {
    const parsed = parseUnifiedDiff(MODIFY)
    const before = parsed.lines.map((l) => `${l.type}:${l.content}`)
    pairSplitRows(parsed.lines)
    expect(parsed.lines.map((l) => `${l.type}:${l.content}`)).toEqual(before)
  })

  it('returns an empty render for an empty diff', () => {
    expect(pairSplitRows([])).toEqual([])
    expect(rows('')).toEqual([])
  })
})
