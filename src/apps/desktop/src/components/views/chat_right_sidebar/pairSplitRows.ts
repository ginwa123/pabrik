import type { ParsedDiffLine } from './parseUnifiedDiff'

/** A row of the side-by-side (split) diff render. */
export interface SplitRow {
  kind: 'hunk' | 'context' | 'change'
  /** Full-width row content (a hunk header). */
  text: string | null
  oldLineNum: number | null
  oldText: string | null
  newLineNum: number | null
  newText: string | null
  /** True for the paired change rows — both sides are tinted from this flag. */
  isChanged: boolean
  /** Indexes into the SOURCE `ParsedDiffLine[]` this row was built from, in source order. */
  sourceIndexes: number[]
}

/** Project a parsed unified diff onto side-by-side rows. */
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
    // Anything else ends the change block.
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

/** Map every source line index to the split row that carries it. */
export function splitRowIndexBySourceIndex(rows: SplitRow[]): Map<number, number> {
  const map = new Map<number, number>()
  rows.forEach((row, rowIndex) => {
    for (const sourceIndex of row.sourceIndexes) {
      if (!map.has(sourceIndex)) map.set(sourceIndex, rowIndex)
    }
  })
  return map
}
