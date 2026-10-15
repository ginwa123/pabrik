import type { ParsedDiffLine } from './parseUnifiedDiff'

/**
 * A row of the side-by-side (split) diff render.
 *
 * `oldText` / `newText` are the line bodies with the diff prefix already
 * stripped (that is what `parseUnifiedDiff` hands over). A `null` side is a
 * FILLER cell — the row is taller than one of the two files at that point
 * (a pure insertion has no old side; a pure deletion has no new side).
 * Renderers must paint a filler as empty, never as an unchanged line.
 */
export interface SplitRow {
  kind: 'hunk' | 'context' | 'change'
  /** Full-width row content (a hunk header). `null` for the two-sided rows,
   * whose content lives in `oldText` / `newText`. */
  text: string | null
  oldLineNum: number | null
  oldText: string | null
  newLineNum: number | null
  newText: string | null
  /** True for the paired change rows — both sides are tinted from this flag. */
  isChanged: boolean
  /**
   * Indexes into the SOURCE `ParsedDiffLine[]` this row was built from, in
   * source order. Review-comment threads anchor to a source line index, so
   * this is what lets a thread keep its position when the user flips between
   * unified and split.
   */
  sourceIndexes: number[]
}

/**
 * Project a parsed unified diff onto side-by-side rows.
 *
 * Inside one hunk git emits a removal run followed by an insertion run, so a
 * change block is paired INDEX-WISE: the 1st removal with the 1st insertion,
 * the 2nd with the 2nd, and whatever is left over on the longer side gets a
 * filler cell opposite it. That is deliberately naive (no similarity scoring
 * — a rename block pairs by position, not by looking alike) because it is
 * predictable and it is what the reader can verify by eye.
 *
 * Hunk headers span the full width; context (and empty) lines render on both
 * sides with their own old/new numbers, which is what makes the two gutters
 * independently readable.
 *
 * Pure: no DOM, no IO. Same input ⇒ same output.
 */
export function pairSplitRows(lines: ParsedDiffLine[]): SplitRow[] {
  const rows: SplitRow[] = []
  let removes: { line: ParsedDiffLine; index: number }[] = []
  let adds: { line: ParsedDiffLine; index: number }[] = []

  const flush = () => {
    if (removes.length === 0 && adds.length === 0) return
    const count = Math.max(removes.length, adds.length)
    for (let i = 0; i < count; i++) {
      const old = removes[i]
      const add = adds[i]
      rows.push({
        kind: 'change',
        text: null,
        oldLineNum: old?.line.oldLineNum ?? null,
        oldText: old ? old.line.content : null,
        newLineNum: add?.line.newLineNum ?? null,
        newText: add ? add.line.content : null,
        isChanged: true,
        sourceIndexes: [old?.index, add?.index].filter((n): n is number => n !== undefined),
      })
    }
    removes = []
    adds = []
  }

  lines.forEach((line, index) => {
    if (line.type === 'remove') {
      removes.push({ line, index })
      return
    }
    if (line.type === 'add') {
      adds.push({ line, index })
      return
    }
    // Anything else ends the change block. A hunk header is full-width; a
    // context/empty line exists on both sides.
    flush()
    if (line.type === 'hunk' || line.type === 'header') {
      rows.push({
        kind: 'hunk',
        text: line.content,
        oldLineNum: null,
        oldText: null,
        newLineNum: null,
        newText: null,
        isChanged: false,
        sourceIndexes: [index],
      })
      return
    }
    rows.push({
      kind: 'context',
      text: null,
      oldLineNum: line.oldLineNum ?? null,
      oldText: line.content,
      newLineNum: line.newLineNum ?? null,
      newText: line.content,
      isChanged: false,
      sourceIndexes: [index],
    })
  })
  flush()

  return rows
}

/**
 * Map every source line index to the split row that carries it.
 *
 * `SidebarDiffView` anchors review threads to a source index; this is how the
 * split render finds the right row for a thread the user left in unified mode
 * (and vice versa). A row's indexes are unique and rows never share one, so
 * the map is exact.
 */
export function splitRowIndexBySourceIndex(rows: SplitRow[]): Map<number, number> {
  const map = new Map<number, number>()
  rows.forEach((row, rowIndex) => {
    for (const sourceIndex of row.sourceIndexes) {
      if (!map.has(sourceIndex)) map.set(sourceIndex, rowIndex)
    }
  })
  return map
}
