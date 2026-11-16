import type { GitFileChange } from '../../../api'

// ── Surgical stage/unstage (SSE-driven) ─────────────────────────────────
export type StageList = 'staged' | 'unstaged' | 'untracked'

/** Where a path belongs after a stage/unstage. */
export function nextStageList(from: StageList, action: 'staged' | 'unstaged'): StageList {
  if (action === 'staged') return 'staged'
  return from === 'untracked' ? 'untracked' : 'unstaged'
}

/** The list the row the user just acted on was in. */
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
    // The `+` button's two homes.
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
    // `git add` on a path that is ALREADY in the index updates that entry — it does not create a second one, so the existing Staged row stays exactly where it is …
    if (from === 'untracked') {
      lists.untracked = lists.untracked.filter((f) => f.path !== path)
    } else {
      lists.unstaged = lists.unstaged.filter((f) => f.path !== path)
    }
    if (!has(lists.staged)) {
      lists.staged = [...lists.staged, { index_status: 'A', worktree_status: ' ', path }]
    }
  } else {
    // The mirror: a path that already has a Changes row keeps it rather than gaining a second one.
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
