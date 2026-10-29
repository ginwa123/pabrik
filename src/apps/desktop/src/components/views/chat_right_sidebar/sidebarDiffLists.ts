import type { GitFileChange, GitFileDiffsResponse } from '../../../api'
import { countDiffLines, parseUnifiedDiff, type DiffSelection, type SplitDiffFile } from './parseUnifiedDiff'
import { folderDiffKey, primeFolderDiffs } from '../../../helpers/folderDiffCache'

export type DiffTarget = { path: string; staged: boolean; untracked?: boolean }

export type DiffCounts = Map<string, { added: number; removed: number }>

export const folderDiffTargets = (
  staged: GitFileChange[],
  unstaged: GitFileChange[],
  untracked: GitFileChange[],
): DiffTarget[] => [
  ...staged.map((f) => ({ path: f.path, staged: true })),
  ...unstaged.map((f) => ({ path: f.path, staged: false })),
  // Untracked files carry the flag to the centre diff's whole-file control:
  // a new file's diff IS the whole file, so nothing needs fetching.
  ...untracked.map((f) => ({ path: f.path, staged: false, untracked: true })),
]

export const selectionOf = (t: DiffTarget, diff_content: string): DiffSelection => {
  const parsed = parseUnifiedDiff(diff_content)
  return {
    path: t.path,
    staged: t.staged,
    lines: parsed.lines,
    added: parsed.added,
    removed: parsed.removed,
    untracked: t.untracked === true,
  }
}

export const errorSelectionOf = (t: DiffTarget): DiffSelection => ({
  path: t.path,
  staged: t.staged,
  lines: [],
  added: 0,
  removed: 0,
  error: 'Failed to load file diff',
  untracked: t.untracked === true,
})

export const folderDiffErrorList = (targets: DiffTarget[]): DiffSelection[] =>
  targets.map((t) => errorSelectionOf(t))

export const folderDiffApplied = (
  cwd: string,
  targets: DiffTarget[],
  batch: GitFileDiffsResponse,
): { counts: DiffCounts; list: DiffSelection[] } => {
  // Hand the payload to every other reader (the file rows' click handler
  // and the standalone GitFileViewer) before rendering, so a click landing
  // in the next few milliseconds is already a cache hit.
  primeFolderDiffs(cwd, batch.diffs)
  // Counts come straight off the payload we already have — no second
  // request, and no re-derivation from the parsed line arrays below.
  const counts: DiffCounts = new Map()
  for (const d of batch.diffs) {
    const { added, removed } = countDiffLines(d.diff_content)
    counts.set(folderDiffKey(d.staged, d.path), { added, removed })
  }
  const byKey = new Map(batch.diffs.map((d) => [folderDiffKey(d.staged, d.path), d.diff_content]))
  const list: DiffSelection[] = targets.map((t) => {
    const content = byKey.get(folderDiffKey(t.staged, t.path))
    if (content !== undefined) return selectionOf(t, content)
    return errorSelectionOf(t)
  })
  return { counts, list }
}

export const prSelections = (files: SplitDiffFile[]): DiffSelection[] =>
  files.map((file) => {
    const parsed = parseUnifiedDiff(file.text)
    return {
      path: file.path,
      staged: false,
      lines: parsed.lines,
      added: parsed.added,
      removed: parsed.removed,
    }
  })

export const prDiffCountsOf = (files: SplitDiffFile[]): DiffCounts => {
  const counts: DiffCounts = new Map()
  for (const file of files) counts.set(file.path, countDiffLines(file.text))
  return counts
}

/** Counts for one PR row, or null when unknown. */
export const prCountsFor = (prCounts: DiffCounts, path: string): { added: number; removed: number } | null =>
  prCounts.get(path) ?? null

/** Counts for one worktree row, or null when unknown. */
export const worktreeCountsFor = (
  worktreeCounts: DiffCounts,
  path: string,
  staged: boolean,
): { added: number; removed: number } | null =>
  worktreeCounts.get(folderDiffKey(staged, path)) ?? null
