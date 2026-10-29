import type { GitFileChange } from '../../../api'

// ── Surgical stage/unstage (SSE-driven) ───────────────────────────────── `+` / `−` used to answer
// with `await loadGitStatus()` — a full `git status --porcelain -uall` plus untracked-directory
// expansion, then a second folder-wide diff request.
export type StageList = 'staged' | 'unstaged' | 'untracked'

/** Where a path belongs after a stage/unstage. Unstaging a file that was ONLY staged leaves it
 * modified in the worktree; unstaging one that was untracked-and-just-staged puts it back under
 * Untracked. */
export function nextStageList(from: StageList, action: 'staged' | 'unstaged'): StageList {
  if (action === 'staged') return 'staged'
  return from === 'untracked' ? 'untracked' : 'unstaged'
}

/** The list the row the user just acted on was in. Derived from the ACTION, not from list
 * precedence, because the action IS the evidence: the `+` button only exists on a Changes or
 * Untracked row and the `−` button only on a Staged one. */
export function actingList(
  lists: {
    staged: GitFileChange[]
    unstaged: GitFileChange[]
    untracked: GitFileChange[]
  },
  path: string,
  action: 'staged' | 'unstaged',
): StageList | null {
  const has = (arr: GitFileChange[]) => arr.some((f) => f.path === path)
  if (action === 'staged') {
    // The `+` button's two homes. Untracked first: staging an untracked path
    // is the only move that can put the row back under Untracked later.
    if (has(lists.untracked)) return 'untracked'
    if (has(lists.unstaged)) return 'unstaged'
    return null
  }
  // The `−` button only ever lives on a Staged row.
  if (has(lists.staged)) return 'staged'
  return null
}

/** Move one path between the three lists. */
export function moveFileBetweenLists(
  lists: {
    staged: GitFileChange[]
    unstaged: GitFileChange[]
    untracked: GitFileChange[]
  },
  path: string,
  action: 'staged' | 'unstaged',
): {
  staged: GitFileChange[]
  unstaged: GitFileChange[]
  untracked: GitFileChange[]
  from: StageList | null
  to: StageList
} {
  const from = actingList(lists, path, action)
  const to = nextStageList(from ?? 'unstaged', action)
  if (from === null || from === to) return { ...lists, from, to }

  const has = (arr: GitFileChange[]) => arr.some((f) => f.path === path)

  if (action === 'staged') {
    // `git add` on a path that is ALREADY in the index updates that entry —
    // it does not create a second one, so the existing Staged row stays
    // exactly where it is instead of being duplicated.
    if (from === 'untracked') {
      lists.untracked = lists.untracked.filter((f) => f.path !== path)
    } else {
      lists.unstaged = lists.unstaged.filter((f) => f.path !== path)
    }
    if (!has(lists.staged)) {
      lists.staged = [...lists.staged, { index_status: 'A', worktree_status: ' ', path }]
    }
  } else {
    // The mirror: a path that already has a Changes row keeps it rather than
    // gaining a second one.
    lists.staged = lists.staged.filter((f) => f.path !== path)
    if (to === 'untracked') {
      if (!has(lists.untracked)) {
        lists.untracked = [...lists.untracked, { index_status: '??', worktree_status: '??', path }]
      }
    } else if (!has(lists.unstaged)) {
      lists.unstaged = [...lists.unstaged, { index_status: ' ', worktree_status: 'M', path }]
    }
  }

  return { ...lists, from, to }
}
