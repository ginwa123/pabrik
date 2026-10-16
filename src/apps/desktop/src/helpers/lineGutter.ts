/** lineGutter — per-line gutter marks for the Code view. The Code view renders worktree (new-file)
 * content, so every mark is keyed by NEW-file line number: `added` (green bar), `modified` (orange
 * bar), `deleted` (red tick where lines were removed). */
export type GutterKind = 'added' | 'modified' | 'deleted'

export interface GutterSourceLine {
  type: 'add' | 'remove' | 'context' | 'header' | 'hunk' | 'empty'
  newLineNum?: number
}

export interface ChangeBlock {
  startLine: number
  endLine: number
}

export interface LineGutter {
  gutters: Map<number, GutterKind>
  blocks: ChangeBlock[]
  added: number
  removed: number
}

const GROUP_END: ReadonlySet<string> = new Set(['context', 'header', 'hunk', 'empty'])

export function buildLineGutter(lines: GutterSourceLine[]): LineGutter {
  const gutters = new Map<number, GutterKind>()
  let added = 0
  let removed = 0
  let maxNew = 0
  for (const line of lines) {
    if (typeof line.newLineNum === 'number' && line.newLineNum > maxNew) maxNew = line.newLineNum
    if (line.type === 'add') added++
    if (line.type === 'remove') removed++
  }

  // One deleted tick per surplus-remove group; placed on the next visible
  // new line (or clamped to the last line at EOF).
  let pendingDelete = false
  const placeTick = (at: number | undefined) => {
    if (at === undefined) {
      pendingDelete = true
      return
    }
    const target = Math.max(1, Math.min(at, maxNew))
    if (!gutters.has(target)) gutters.set(target, 'deleted')
    pendingDelete = false
  }

  // Current maximal run of changed lines.
  let removeCount = 0
  let addedLines: number[] = []
  const flushGroup = (nextNewLine: number | undefined) => {
    if (removeCount === 0 && addedLines.length === 0) return
    const paired = Math.min(removeCount, addedLines.length)
    addedLines.forEach((newLine, i) => {
      gutters.set(newLine, i < paired ? 'modified' : 'added')
    })
    if (removeCount > addedLines.length) {
      // Surplus removes: tick the last added row, else the next new line.
      const anchor = addedLines.length > 0 ? addedLines[addedLines.length - 1] : nextNewLine
      placeTick(anchor)
    }
    removeCount = 0
    addedLines = []
  }

  for (const line of lines) {
    if (GROUP_END.has(line.type)) {
      flushGroup(line.newLineNum)
      // A pending EOF-style tick lands on the next visible new line.
      if (pendingDelete && typeof line.newLineNum === 'number') placeTick(line.newLineNum)
      continue
    }
    if (line.type === 'remove') {
      removeCount++
      continue
    }
    if (line.type === 'add' && typeof line.newLineNum === 'number') {
      addedLines.push(line.newLineNum)
    }
  }
  flushGroup(undefined)
  if (pendingDelete && maxNew > 0) placeTick(maxNew)

  const marked = [...gutters.keys()].sort((a, b) => a - b)
  const blocks: ChangeBlock[] = []
  for (const line of marked) {
    const last = blocks[blocks.length - 1]
    if (last && line === last.endLine + 1) {
      last.endLine = line
    } else {
      blocks.push({ startLine: line, endLine: line })
    }
  }

  return { gutters, blocks, added, removed }
}
