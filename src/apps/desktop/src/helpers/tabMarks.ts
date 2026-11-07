/**    * The marks a file tab wears: the file's own `+N −M`, and whether those numbers moved since the tab
 * was last looked at. Pure, so the rule can be read and tested without a fetch. */
import type { Tab } from './tabTarget'

export type TabCounts = { added: number; removed: number }

/** The file a tab shows. Empty for the session's own tab and for anything without a file target. */
export function fileOf(tab: Tab): string {
  return tab.query.file ?? ''
}

/** The cwd the tab was opened with, never the sidebar's: a tab keeps its own worktree's diff. */
export function cwdOf(tab: Tab): string {
  return tab.query.cwd ?? ''
}

export type TabMark = {
  /** `null` when the file has no changes, so a clean tab stays quiet. */
  counts: TabCounts | null
  unseen: boolean
}

export function markOf(
  tab: Tab,
  active: boolean,
  counts: Record<string, TabCounts>,
  seen: Record<string, TabCounts>,
): TabMark {
  const file = fileOf(tab)
  const current = file ? counts[file] : undefined
  if (!current || (current.added === 0 && current.removed === 0))
    return { counts: null, unseen: false }
  // The tab you are looking at is never "unseen": you are looking at it.
  if (active) return { counts: current, unseen: false }
  const before = seen[file]
  const unseen = !!before && (before.added !== current.added || before.removed !== current.removed)
  return { counts: current, unseen }
}

/** Record what the user has now seen, for the files of the tabs that are on screen. */
export function recordSeen(
  seen: Record<string, TabCounts>,
  counts: Record<string, TabCounts>,
  files: string[],
): Record<string, TabCounts> {
  let next = seen
  for (const file of files) {
    const current = counts[file]
    if (!current) continue
    const before = next[file]
    if (before && before.added === current.added && before.removed === current.removed) continue
    if (next === seen) next = { ...seen }
    next[file] = current
  }
  return next
}
