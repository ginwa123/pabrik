/**
 * Diff algorithm + diff-row renderers for the DiffView component.
 *
 * Implementation note: we use a classic LCS (Longest Common Subsequence) DP
 * to compute the shortest edit script. O(N*M) time and space, simple to
 * verify correct. For typical `text_replace` edits (< 100 lines diff against
 * files < 5,000 lines), this returns in < 10 ms in jsdom.
 *
 * A hand-rolled Myers O(ND) variant would be asymptotically faster, but is
 * significantly harder to get right and not worth the complexity at this scale.
 *
 * For the specific case where N=0 or M=0 (pure insert or pure delete) we skip
 * the DP entirely.
 */

/** A single op in the shortest edit script (SES). */
export interface DiffOp {
  type: 'equal' | 'insert' | 'delete'
  /** 1-indexed; null for inserts (no corresponding before line). */
  beforeLine: number | null
  /** 1-indexed; null for deletes (no corresponding after line). */
  afterLine: number | null
  text: string
}

/** Per-word change within a single changed line (for word-level highlights). */
export interface InlineChange {
  type: 'equal' | 'insert' | 'delete'
  /** Start offset (inclusive) within the line text. */
  start: number
  /** End offset (exclusive). */
  end: number
  text: string
}

/** A row in a split-view render — represents one line on each side. */
export interface SplitRow {
  /** The text shown on the left (before) side; null for inserts. */
  beforeText: string | null
  /** 1-indexed line number on the before side; null for inserts. */
  beforeLine: number | null
  /** Per-word changes for the before side. */
  beforeChanges?: InlineChange[]
  /** The text shown on the right (after) side; null for deletes. */
  afterText: string | null
  /** 1-indexed line number on the after side; null for deletes. */
  afterLine: number | null
  /** Per-word changes for the after side. */
  afterChanges?: InlineChange[]
  /** true when at least one side has non-equal content (i.e. the line changed). */
  isChanged: boolean
}

/** A row in a unified-view render — git-style. */
export interface UnifiedRow {
  kind: 'context' | 'delete' | 'insert' | 'hunk'
  /** Line number on the before side (for context/delete). */
  beforeLine?: number
  /** Line number on the after side (for context/insert). */
  afterLine?: number
  text: string
}

/** Split a string into lines, preserving the original content. */
export function splitLines(s: string): string[] {
  if (s === '') return []
  const lines = s.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') {
    lines.pop()
  }
  return lines
}

/**  * Compute the shortest edit script via LCS DP. Strategy: compute LCS lengths matrix `dp[i][j]` =
 * LCS length of `before[0..i)` and `after[0..j)`. Walk back from `dp[N][M]` to construct the SES in
 * reverse order. */
export function myersDiff(before: string[], after: string[]): DiffOp[] {
  const N = before.length
  const M = after.length

  if (N === 0 && M === 0) return []
  if (N === 0) {
    return after.map((text, i): DiffOp => ({
      type: 'insert',
      beforeLine: null,
      afterLine: i + 1,
      text,
    }))
  }
  if (M === 0) {
    return before.map((text, i): DiffOp => ({
      type: 'delete',
      beforeLine: i + 1,
      afterLine: null,
      text,
    }))
  }

  // Build LCS length table. Use `Uint32Array` rows for speed.
  const dp: Uint32Array[] = Array.from({ length: N + 1 })
  for (let i = 0; i <= N; i++) dp[i] = new Uint32Array(M + 1)

  for (let i = 1; i <= N; i++) {
    const row = dp[i]!
    const prevRow = dp[i - 1]!
    const beforeLine = before[i - 1]!
    for (let j = 1; j <= M; j++) {
      if (beforeLine === after[j - 1]) {
        row[j] = prevRow[j - 1]! + 1
      } else {
        row[j] = Math.max(prevRow[j]!, row[j - 1]!)
      }
    }
  }

  // Walk back to build SES in reverse (then reverse at the end).
  const opsRev: DiffOp[] = []
  let i = N
  let j = M
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && before[i - 1] === after[j - 1]) {
      opsRev.push({
        type: 'equal',
        beforeLine: i,
        afterLine: j,
        text: before[i - 1]!,
      })
      i--
      j--
    } else if (j > 0 && (i === 0 || dp[i]![j - 1]! >= dp[i - 1]![j]!)) {
      opsRev.push({
        type: 'insert',
        beforeLine: null,
        afterLine: j,
        text: after[j - 1]!,
      })
      j--
    } else {
      opsRev.push({
        type: 'delete',
        beforeLine: i,
        afterLine: null,
        text: before[i - 1]!,
      })
      i--
    }
  }

  return opsRev.reverse()
}

/** Split a line into word-level tokens for word-level diffing. */
function tokenizeWords(line: string): string[] {
  if (line === '') return []
  const tokens: string[] = []
  let i = 0
  while (i < line.length) {
    if (line[i] === ' ' || line[i] === '\t') {
      tokens.push(line[i]!)
      i++
    } else {
      let j = i
      while (j < line.length && line[j] !== ' ' && line[j] !== '\t') j++
      tokens.push(line.slice(i, j))
      i = j
    }
  }
  return tokens
}

/** Per-line word-level diff using LCS on tokens. Returns inline changes that
 * can be applied as `<span>` highlights. */
export function computeInlineWordChanges(before: string, after: string): InlineChange[] {
  const aTokens = tokenizeWords(before)
  const bTokens = tokenizeWords(after)
  const ops = myersDiff(aTokens, bTokens)
  const out: InlineChange[] = []
  let afterOffset = 0
  for (const op of ops) {
    const text = op.text
    if (op.type === 'equal') {
      out.push({
        type: 'equal',
        start: afterOffset,
        end: afterOffset + text.length,
        text,
      })
      afterOffset += text.length
    } else if (op.type === 'delete') {
      out.push({
        type: 'delete',
        start: afterOffset,
        end: afterOffset,
        text,
      })
    } else {
      out.push({
        type: 'insert',
        start: afterOffset,
        end: afterOffset + text.length,
        text,
      })
      afterOffset += text.length
    }
  }
  return out
}

/** Convert a SES into a row-based split view (left = before, right = after).
 * Equal lines produce matched rows; insert ops leave the before cell empty;
 * delete ops leave the after cell empty.
 * Adjacent delete+insert pairs are paired into single rows so the change
 * appears as one logical row pair (visually like a real diff). */
export function computeSplitView(before: string[], after: string[]): SplitRow[] {
  const ops = myersDiff(before, after)
  const rows: SplitRow[] = []

  for (let i = 0; i < ops.length; i++) {
    const op = ops[i]!
    if (op.type === 'equal') {
      rows.push({
        beforeText: op.text,
        beforeLine: op.beforeLine,
        afterText: op.text,
        afterLine: op.afterLine,
        isChanged: false,
      })
    } else if (op.type === 'delete') {
      // Look ahead: if next op is an insert, pair them
      const next = ops[i + 1]
      if (next && next.type === 'insert') {
        rows.push({
          beforeText: op.text,
          beforeLine: op.beforeLine,
          afterText: next.text,
          afterLine: next.afterLine,
          isChanged: true,
          beforeChanges: computeInlineWordChanges(op.text, next.text),
          afterChanges: computeInlineWordChanges(op.text, next.text),
        })
        i++ // consume the insert
      } else {
        rows.push({
          beforeText: op.text,
          beforeLine: op.beforeLine,
          afterText: null,
          afterLine: null,
          isChanged: true,
          beforeChanges: computeInlineWordChanges(op.text, ''),
        })
      }
    } else {
      // insert (not preceded by a delete — pure insertion)
      rows.push({
        beforeText: null,
        beforeLine: null,
        afterText: op.text,
        afterLine: op.afterLine,
        isChanged: true,
        afterChanges: computeInlineWordChanges('', op.text),
      })
    }
  }
  return rows
}

/** Compute unified view with `contextLines` of context around changes and
 * `@@ -start,count +start,count @@` hunk headers between hunks. */
export function computeUnifiedView(
  before: string[],
  after: string[],
  contextLines = 3,
): UnifiedRow[] {
  const ops = myersDiff(before, after)
  if (ops.length === 0) return []
  const rows: UnifiedRow[] = []

  // Group ops into hunks. When we accumulate more than 2*contextLines of
  // trailing equal lines, split the current hunk (keeping contextLines of
  // trailing context as leading context for the next hunk).
  type Group = { ops: DiffOp[] }
  const groups: Group[] = []
  let current: Group = { ops: [] }
  let contextBudget = 0

  for (const op of ops) {
    if (op.type === 'equal') {
      if (contextBudget >= 2 * contextLines && current.ops.length > 0) {
        // Move the trailing contextLines equal-ops to the start of the next hunk.
        const trailingCount = contextLines
        const trimmed = current.ops.splice(current.ops.length - trailingCount, trailingCount)
        groups.push(current)
        current = { ops: trimmed }
        contextBudget = 0
      }
      current.ops.push(op)
      contextBudget++
    } else {
      current.ops.push(op)
      contextBudget = 0
    }
  }
  if (current.ops.length > 0) groups.push(current)

  for (const group of groups) {
    // Hunk header: first before-line / first after-line, plus counts.
    const beforeCount = group.ops.filter(
      (o) => o.type === 'equal' || o.type === 'delete',
    ).length
    const afterCount = group.ops.filter(
      (o) => o.type === 'equal' || o.type === 'insert',
    ).length
    const firstBeforeOp = group.ops.find((o) => o.beforeLine !== null)
    const firstAfterOp = group.ops.find((o) => o.afterLine !== null)
    const firstBeforeLine = firstBeforeOp?.beforeLine ?? 1
    const firstAfterLine = firstAfterOp?.afterLine ?? 1
    rows.push({
      kind: 'hunk',
      text: `@@ -${firstBeforeLine},${beforeCount} +${firstAfterLine},${afterCount} @@`,
    })
    for (const op of group.ops) {
      let kind: UnifiedRow['kind']
      let prefix: string
      if (op.type === 'equal') {
        kind = 'context'
        prefix = ' '
      } else if (op.type === 'delete') {
        kind = 'delete'
        prefix = '-'
      } else {
        kind = 'insert'
        prefix = '+'
      }
      rows.push({
        kind,
        beforeLine: op.beforeLine ?? undefined,
        afterLine: op.afterLine ?? undefined,
        text: `${prefix}${op.text}`,
      })
    }
  }

  return rows
}

/**
 * Single-column inline view (one row per op). Useful for collapsed/preview mode.
 */
export function computeInlineView(before: string[], after: string[]): DiffOp[] {
  return myersDiff(before, after)
}