import type { GitFileChange } from '../../../api'
import { parseUnifiedDiff, type SplitDiffFile } from './parseUnifiedDiff'

// ── Row anatomy ─────────────────────────────────────────────────────────── The panel shows 40+
// rows of repo-relative paths that mostly share a long identical prefix. Two helpers turn that into
// something scannable.
export function pathParts(path: string): { dir: string; name: string } {
  const i = path.lastIndexOf('/')
  if (i < 0) return { dir: '', name: path }
  return { dir: path.slice(0, i + 1), name: path.slice(i + 1) }
}

// Status as a letter chip rather than a colour emoji. Six emoji render at six different pixel sizes
// next to 12px paths and cannot be asserted on; one letter in a fixed 16px box cannot drift. See
// AGENTS.md ("No Emoji as Icons").
export type StatusChip = { letter: string; bg: string; fg: string; title: string }

const STATUS_CHIPS: Record<string, StatusChip> = {
  M: {
    letter: 'M',
    bg: 'color-mix(in srgb, var(--color-orange) 18%, transparent)',
    fg: 'var(--color-orange)',
    title: 'Modified',
  },
  A: {
    letter: 'A',
    bg: 'color-mix(in srgb, var(--color-green) 18%, transparent)',
    fg: 'var(--color-green)',
    title: 'Added',
  },
  D: {
    letter: 'D',
    bg: 'color-mix(in srgb, var(--semantic-error) 18%, transparent)',
    fg: 'var(--semantic-error)',
    title: 'Deleted',
  },
  R: {
    letter: 'R',
    bg: 'color-mix(in srgb, var(--color-violet) 18%, transparent)',
    fg: 'var(--color-violet)',
    title: 'Renamed',
  },
  C: { letter: 'C', bg: 'var(--color-bg-p1)', fg: 'var(--semantic-text-dim)', title: 'Copied' },
  '??': {
    letter: '?',
    bg: 'var(--color-bg-p1)',
    fg: 'var(--semantic-text-dim)',
    title: 'Untracked',
  },
}

const UNKNOWN_CHIP: StatusChip = {
  letter: '?',
  bg: 'var(--color-bg-p1)',
  fg: 'var(--semantic-text-dim)',
  title: 'Changed',
}

const UNTRACKED_CHIP: StatusChip = {
  letter: '?',
  bg: 'var(--color-bg-p1)',
  fg: 'var(--semantic-text-dim)',
  title: 'Untracked',
}

export const chipFor = (status: string): StatusChip => STATUS_CHIPS[status] ?? UNKNOWN_CHIP

export const chipForFile = (file: GitFileChange): StatusChip => {
  if (file.index_status === '??') return UNTRACKED_CHIP
  const indexStatus = file.index_status === ' ' ? '' : file.index_status
  if (indexStatus) return chipFor(indexStatus)
  const worktreeStatus = file.worktree_status === ' ' ? '' : file.worktree_status
  if (worktreeStatus) return chipFor(worktreeStatus)
  return UNKNOWN_CHIP
}

// ── File filter ─────────────────────────────────────────────────────────── A 40-file list needs a
// way to narrow it. Shown only past FILTER_MIN_ROWS so a three-file panel is not asked to carry a
// search box.
export const FILTER_MIN_ROWS = 8

export const isFilterActive = (query: string): boolean => query.trim() !== ''

export const pathMatchesFilter = (path: string, query: string): boolean => {
  const q = query.trim().toLowerCase()
  return q === '' || path.toLowerCase().includes(q)
}

export const filterRows = <T extends { path: string }>(rows: T[], query: string): T[] =>
  rows.filter((f) => pathMatchesFilter(f.path, query))

// The bar stays put once it appears. Hiding it on the first keystroke
// would leave no way to widen the query or clear it — the input takes the
// focus, loses itself, and strands the state.
export const showsFilter = (total: number): boolean => total > FILTER_MIN_ROWS

/** A preview is a glance, not the diff: the first lines, and a count of what is left. */
export const PREVIEW_MAX_LINES = 14

/** The before/after sign and colour of one preview line. */
const PREVIEW_LINE: Record<string, { sign: string; color: string; background: string }> = {
  add: {
    sign: '+',
    color: 'var(--color-green)',
    background: 'color-mix(in srgb, var(--color-green) 12%, transparent)',
  },
  remove: {
    sign: '−',
    color: 'var(--color-red)',
    background: 'color-mix(in srgb, var(--color-red) 12%, transparent)',
  },
  context: { sign: ' ', color: 'var(--semantic-text-dim)', background: 'transparent' },
  hunk: { sign: '', color: 'var(--color-blue)', background: 'rgba(139, 164, 176, 0.08)' },
}

export const previewFor = (files: SplitDiffFile[], path: string | null) => {
  if (!path) return null
  const file = files.find((f) => f.path === path)
  if (!file) return null
  const parsed = parseUnifiedDiff(file.text)
  const lines = parsed.lines.filter(
    (line) =>
      line.type === 'add' || line.type === 'remove' || line.type === 'context' || line.type === 'hunk',
  )
  return {
    lines: lines.slice(0, PREVIEW_MAX_LINES).map((line) => {
      const look = PREVIEW_LINE[line.type] ?? PREVIEW_LINE.context
      return { key: line.lineIndex, content: line.content, ...look }
    }),
    hidden: Math.max(0, lines.length - PREVIEW_MAX_LINES),
  }
}
