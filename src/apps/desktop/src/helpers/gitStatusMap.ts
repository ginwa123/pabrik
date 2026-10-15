/**
 * gitStatusMap — pure join logic between `GET /api/git/changes` and the
 * file-explorer tree.
 *
 * The backend returns three path lists (`staged_files`, `modified_files`,
 * `untracked_files`) with repo-relative paths and single-char porcelain
 * statuses (`line[0..1]` in `parseGitStatus`, so untracked arrives as
 * `"?"`, never `"??"`). This module folds those lists into one
 * `path -> badge` map plus the rollups the explorer needs (per-folder
 * counts, footer summary). No DOM, no fetch — takes the wire response,
 * returns data.
 */
import type { GitChangesResponse, GitFileChange } from '../api'

export type GitBadgeKind = 'staged' | 'modified' | 'untracked' | 'deleted' | 'renamed'

export interface GitBadge {
  kind: GitBadgeKind
  /** Single-glyph label the explorer renders (`A`, `M`, `D`, `R`, `??`). */
  badge: string
}

/** Porcelain chars arrive padded (`" "`, `"?"`); normalize before comparing. */
function norm(status: string): string {
  const trimmed = status.trim()
  return trimmed === '' ? ' ' : trimmed
}

/** Badge for one wire entry. Staged state wins when both sides are set
 * (e.g. `A`/`M` = staged new file edited again in the worktree). */
export function displayStatusForChange(change: GitFileChange): GitBadge {
  const index = norm(change.index_status)
  const worktree = norm(change.worktree_status)
  if (index === '?' || worktree === '?') return { kind: 'untracked', badge: '??' }
  const code = index !== ' ' ? index : worktree
  if (code === 'A') return { kind: 'staged', badge: 'A' }
  if (code === 'D') return { kind: 'deleted', badge: 'D' }
  if (code === 'R') return { kind: 'renamed', badge: 'R' }
  return { kind: 'modified', badge: 'M' }
}

/**  * Fold the three wire lists into one map. Insert order is deliberate: untracked, then modified,
 * then staged — so a path present in several lists (staged + further worktree edits) keeps its
 * staged badge. */
export function buildGitStatusMap(changes: GitChangesResponse): Map<string, GitBadge> {
  const map = new Map<string, GitBadge>()
  for (const file of changes.untracked_files ?? []) map.set(file.path, displayStatusForChange(file))
  for (const file of changes.modified_files ?? []) map.set(file.path, displayStatusForChange(file))
  for (const file of changes.staged_files ?? []) map.set(file.path, displayStatusForChange(file))
  return map
}

/** Repo-relative key for an absolute explorer path, or null when outside. */
function relativeToRoot(repoRoot: string, absolutePath: string): string | null {
  const root = repoRoot.endsWith('/') ? repoRoot.slice(0, -1) : repoRoot
  if (absolutePath === root) return ''
  if (!absolutePath.startsWith(root + '/')) return null
  return absolutePath.slice(root.length + 1)
}

/** Badge for one explorer row, or null when the path is clean / outside. */
export function statusForExplorerPath(
  map: Map<string, GitBadge>,
  repoRoot: string,
  absolutePath: string,
): GitBadge | null {
  const relative = relativeToRoot(repoRoot, absolutePath)
  if (relative === null || relative === '') return null
  return map.get(relative) ?? null
}

/** Changed descendants under a folder (itself included) for count badges. */
export function countChangedUnder(
  map: Map<string, GitBadge>,
  repoRoot: string,
  dirAbsolutePath: string,
): number {
  const relative = relativeToRoot(repoRoot, dirAbsolutePath)
  if (relative === null) return 0
  if (relative === '') return map.size
  const prefix = relative + '/'
  let count = 0
  for (const key of map.keys()) {
    if (key === relative || key.startsWith(prefix)) count++
  }
  return count
}

export interface GitStatusSummary {
  modified: number
  staged: number
  deleted: number
  untracked: number
  renamed: number
  total: number
}

/** Per-class counts for the explorer footer summary. */
export function summarizeGitStatuses(map: Map<string, GitBadge>): GitStatusSummary {
  const summary: GitStatusSummary = {
    modified: 0,
    staged: 0,
    deleted: 0,
    untracked: 0,
    renamed: 0,
    total: 0,
  }
  for (const badge of map.values()) {
    summary[badge.kind]++
    summary.total++
  }
  return summary
}
