/** lineGutter — maps whole-file diff lines to per-line gutter marks for the Code view (`added` /
 * `modified` / `deleted`), plus change blocks for the up/down navigator. Keys are NEW-file line
 * numbers: the Code view renders worktree content, so every mark must address a visible row. */
import { describe, expect, it } from 'vitest'
import { buildLineGutter } from '../lineGutter'
import { parseUnifiedDiff } from '../../components/views/chat_right_sidebar/parseUnifiedDiff'

const ADDITION = [
  'diff --git a/x.go b/x.go',
  'index 111..222 100644',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,2 +1,4 @@',
  ' line1',
  '+line2',
  '+line3',
  ' line4',
].join('\n')

const MODIFY = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,3 +1,3 @@',
  ' line1',
  '-old2',
  '+new2',
  ' line3',
].join('\n')

const DELETE_MID = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,4 +1,3 @@',
  ' line1',
  '-gone2',
  ' line3',
  ' line4',
].join('\n')

const MIXED_MORE_REMOVED = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,4 +1,3 @@',
  ' line1',
  '-old2',
  '-old3',
  '+new2',
  ' line4',
].join('\n')

const MIXED_MORE_ADDED = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,3 +1,4 @@',
  ' line1',
  '-old2',
  '+new2',
  '+extra3',
  ' line4',
].join('\n')

const DELETE_EOF = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,3 +1,2 @@',
  ' line1',
  ' line2',
  '-gone3',
].join('\n')

const TWO_HUNKS = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,3 +1,3 @@',
  ' line1',
  '-old',
  '+new',
  ' line3',
  '@@ -10,2 +10,3 @@',
  ' line10',
  '+line11',
  ' line12',
].join('\n')

function gutterOf(diff: string): Map<number, string> {
  const parsed = parseUnifiedDiff(diff)
  return buildLineGutter(parsed.lines).gutters as Map<number, string>
}

describe('buildLineGutter', () => {
  it('marks a pure addition run as added on the new lines', () => {
    expect([...gutterOf(ADDITION).entries()]).toEqual([
      [2, 'added'],
      [3, 'added'],
    ])
  })

  it('marks a remove/add pair as modified', () => {
    expect([...gutterOf(MODIFY).entries()]).toEqual([[2, 'modified']])
  })

  it('ticks the new line where a mid-file deletion happened', () => {
    expect([...gutterOf(DELETE_MID).entries()]).toEqual([[2, 'deleted']])
  })

  it('pairs surplus removes into a deleted tick on the modified line', () => {
    // R=2, A=1: new2 is modified, the extra removed line ticks the same row.
    expect([...gutterOf(MIXED_MORE_REMOVED).entries()]).toEqual([[2, 'modified']])
  })

  it('marks surplus adds beyond the pair as added', () => {
    expect([...gutterOf(MIXED_MORE_ADDED).entries()]).toEqual([
      [2, 'modified'],
      [3, 'added'],
    ])
  })

  it('clamps an EOF deletion tick to the last line', () => {
    expect([...gutterOf(DELETE_EOF).entries()]).toEqual([[2, 'deleted']])
  })

  it('returns empty marks for an empty diff', () => {
    const out = buildLineGutter(parseUnifiedDiff('').lines)
    expect(out.gutters.size).toBe(0)
    expect(out.blocks).toEqual([])
    expect(out.added).toBe(0)
    expect(out.removed).toBe(0)
  })

  it('counts added and removed lines', () => {
    const out = buildLineGutter(parseUnifiedDiff(MIXED_MORE_REMOVED).lines)
    expect(out.added).toBe(1)
    expect(out.removed).toBe(2)
  })

  it('merges adjacent marks into one change block', () => {
    const out = buildLineGutter(parseUnifiedDiff(ADDITION).lines)
    expect(out.blocks).toEqual([{ startLine: 2, endLine: 3 }])
  })

  it('keeps distant hunks as separate change blocks', () => {
    const out = buildLineGutter(parseUnifiedDiff(TWO_HUNKS).lines)
    expect(out.blocks).toEqual([
      { startLine: 2, endLine: 2 },
      { startLine: 11, endLine: 11 },
    ])
  })
})
