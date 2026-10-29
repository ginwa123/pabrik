export type StatusBadgeRow = {
  id: string
  last_finish_reason?: string
  needs_human_review?: boolean
}

export const isAwaitingReview = (row: StatusBadgeRow): boolean =>
  row.needs_human_review === true && row.last_finish_reason === 'stop'

// The `last_finish_reason === 'stop'` gate is load-bearing: without it a
// stale `needs_human_review: false` + `finish_reason: 'tool_calls'`
// state paints a phantom "reviewed" checkmark mid-turn.
export const isReviewed = (row: StatusBadgeRow): boolean =>
  !isAwaitingReview(row) && row.last_finish_reason === 'stop'

// Migration 082 - "AI is ahead of you" stale-dot check.
// Both come from the backend as unix-ms strings (Migration 075
// convention) - we compare as numbers.
export const isStale = (human: string | undefined, updated: string | undefined): boolean => {
  if (!human) return false
  if (!updated) return false
  // Both fields are SQLite datetime UTC strings ('YYYY-MM-DD HH:MM:SS') - identical format - so
  // lexicographic string comparison is the most accurate (and fastest) way to detect 'updated_at >
  // human_time'.
  return updated > human
}

// Single-badge rule: the orange awaiting-review dot already covers
// the "AI is ahead" state, so the amber stale dot stays hidden then.
// Without this both dots paint together (same SQL predicate).
export type StaleDotRow = StatusBadgeRow & {
  last_human_touched_at?: string
  updated_at?: string
}

export const shouldShowStaleDot = (item: StaleDotRow): boolean => {
  if (isAwaitingReview(item)) return false
  return isStale(item.last_human_touched_at, item.updated_at)
}

export type ChatRow = {
  id: string
  cwd?: string
  git_worktree_cwd?: string
  git_branch?: string
}

export const effectiveChatCwd = (item: ChatRow): string => item.git_worktree_cwd || item.cwd || ''

export const branchStyle = (status?: string): Record<string, string> => {
  const s = status || ''
  if (s === 'merged') return { color: 'var(--color-violet)', fontWeight: '600' }
  if (s === 'closed') return { color: 'var(--semantic-error)', fontWeight: '600' }
  if (s === 'open') return { color: 'var(--color-green)', fontWeight: '600' }
  return { color: 'var(--color-orange)', fontWeight: '600' }
}

export const branchTitle = (item: ChatRow, status?: string, conflict?: boolean): string => {
  const branch = item.git_branch || ''
  const s = status || ''
  const conflictSuffix = conflict ? ' — merge conflicts' : ''
  const base =
    s === 'merged'
      ? `PR merged — ${branch}`
      : s === 'closed'
        ? `PR closed — ${branch}`
        : s === 'open'
          ? `PR open${conflictSuffix} — ${branch}`
          : conflict
            ? `${branch} — merge conflicts`
            : branch
  // Surface the worktree path alongside the branch so the full
  // checkout location stays discoverable on hover.
  if (item.git_worktree_cwd) return `${base} — ${item.git_worktree_cwd}`
  return base
}
