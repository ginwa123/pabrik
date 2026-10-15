/** gitStatusMap — pure join logic between `GET /api/git/changes` and the
 * explorer tree. No DOM, no fetch: takes the wire response, returns data.
 * Wire-format note: the backend sends SINGLE-char statuses (`"?"`, not
 * `"??"` — see `parseGitStatus` in `src/http_handlers/git_changes.zig`,
 * which slices `line[0..1]`). The helper accepts both spellings so the
 * badges stay correct regardless of which side pads the char. */
import { describe, expect, it } from 'vitest'
import {
  buildGitStatusMap,
  countChangedUnder,
  displayStatusForChange,
  statusForExplorerPath,
  summarizeGitStatuses,
} from '../gitStatusMap'
import type { GitChangesResponse } from '../../api'

const CHANGES: GitChangesResponse = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [
    { index_status: 'A', worktree_status: ' ', path: 'src/new.ts' },
    // Staged new file, then edited again in the worktree: present in BOTH
    // lists (backend puts it in staged AND modified). Staged must win.
    { index_status: 'A', worktree_status: 'M', path: 'src/staged_then_edited.ts' },
  ],
  modified_files: [
    { index_status: ' ', worktree_status: 'M', path: 'src/app.ts' },
    { index_status: 'A', worktree_status: 'M', path: 'src/staged_then_edited.ts' },
    { index_status: ' ', worktree_status: 'D', path: 'src/gone.ts' },
    { index_status: 'R', worktree_status: ' ', path: 'src/renamed.ts' },
  ],
  untracked_files: [{ index_status: '?', worktree_status: '?', path: 'notes/todo.md' }],
}

describe('displayStatusForChange', () => {
  it('marks single-char "?" statuses as untracked with a ?? badge', () => {
    expect(
      displayStatusForChange({ index_status: '?', worktree_status: '?', path: 'x' }),
    ).toEqual({ kind: 'untracked', badge: '??' })
  })

  it('marks a staged new file as staged with an A badge', () => {
    expect(displayStatusForChange({ index_status: 'A', worktree_status: ' ', path: 'x' })).toEqual(
      { kind: 'staged', badge: 'A' },
    )
  })

  it('marks an unstaged modification as modified with an M badge', () => {
    expect(displayStatusForChange({ index_status: ' ', worktree_status: 'M', path: 'x' })).toEqual(
      { kind: 'modified', badge: 'M' },
    )
  })

  it('marks a staged modification as modified with an M badge', () => {
    expect(displayStatusForChange({ index_status: 'M', worktree_status: ' ', path: 'x' })).toEqual(
      { kind: 'modified', badge: 'M' },
    )
  })

  it('marks deletions with a D badge', () => {
    expect(displayStatusForChange({ index_status: ' ', worktree_status: 'D', path: 'x' })).toEqual(
      { kind: 'deleted', badge: 'D' },
    )
  })

  it('marks renames with an R badge', () => {
    expect(displayStatusForChange({ index_status: 'R', worktree_status: ' ', path: 'x' })).toEqual(
      { kind: 'renamed', badge: 'R' },
    )
  })
})

describe('buildGitStatusMap', () => {
  it('indexes every changed path once', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(map.size).toBe(6)
    expect(map.get('src/app.ts')).toEqual({ kind: 'modified', badge: 'M' })
    expect(map.get('notes/todo.md')).toEqual({ kind: 'untracked', badge: '??' })
  })

  it('prefers the staged entry when a path is in both lists', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(map.get('src/staged_then_edited.ts')).toEqual({ kind: 'staged', badge: 'A' })
  })

  it('returns an empty map for a clean tree', () => {
    const map = buildGitStatusMap({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    expect(map.size).toBe(0)
  })
})

describe('statusForExplorerPath', () => {
  it('resolves an absolute explorer path against the repo root', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(statusForExplorerPath(map, '/repo', '/repo/src/app.ts')).toEqual({
      kind: 'modified',
      badge: 'M',
    })
  })

  it('returns null for clean files and paths outside the repo', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(statusForExplorerPath(map, '/repo', '/repo/src/clean.ts')).toBeNull()
    expect(statusForExplorerPath(map, '/repo', '/other/src/app.ts')).toBeNull()
  })

  it('tolerates a trailing slash on the repo root', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(statusForExplorerPath(map, '/repo/', '/repo/src/app.ts')).toEqual({
      kind: 'modified',
      badge: 'M',
    })
  })
})

describe('countChangedUnder', () => {
  it('rolls changed descendants up into their folder', () => {
    const map = buildGitStatusMap(CHANGES)
    expect(countChangedUnder(map, '/repo', '/repo/src')).toBe(5)
    expect(countChangedUnder(map, '/repo', '/repo/notes')).toBe(1)
    expect(countChangedUnder(map, '/repo', '/repo')).toBe(6)
    expect(countChangedUnder(map, '/repo', '/repo/empty')).toBe(0)
  })
})

describe('summarizeGitStatuses', () => {
  it('counts each status class for the footer', () => {
    expect(summarizeGitStatuses(buildGitStatusMap(CHANGES))).toEqual({
      modified: 1,
      staged: 2,
      deleted: 1,
      untracked: 1,
      renamed: 1,
      total: 6,
    })
  })
})
