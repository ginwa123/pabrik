/** Behavioural tests for the persistent git-status cache (SWR paint).
 * The cache's contract: keyed by cwd, survives reloads (localStorage),
 * fail-silent on every storage failure, and never returns a shape that
 * ChatView's chip cannot render (corrupt/foreign JSON → null). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { GitStatus } from '@/api'
import { readGitStatusCache, writeGitStatusCache, clearGitStatusCache } from '../gitStatusCache'

const STATUS: GitStatus = {
  is_git_repo: true,
  branch: 'feature/cache',
  has_changes: true,
  is_clean: false,
  current: 'feature/cache',
  status: 'modified',
}

// jsdom in this project's Vitest does not reliably provide localStorage
// (same guard as ChatView.worktreeSidebar.spec.ts / nav.spec.ts).
function ensureLocalStorage(): void {
  if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
    const store: Record<string, string> = {}
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v)
      },
      removeItem: (k: string) => {
        delete store[k]
      },
      clear: () => {
        for (const k in store) delete store[k]
      },
      key: () => null,
      length: 0,
    } as Storage)
  }
}

describe('gitStatusCache', () => {
  beforeEach(() => {
    ensureLocalStorage()
    localStorage.clear()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('round-trips a status for a cwd', () => {
    writeGitStatusCache('/repo/a', STATUS)
    expect(readGitStatusCache('/repo/a')).toEqual(STATUS)
  })

  it('isolates entries per cwd', () => {
    writeGitStatusCache('/repo/a', STATUS)
    expect(readGitStatusCache('/repo/b')).toBeNull()
  })

  it('returns null on a miss', () => {
    expect(readGitStatusCache('/repo/never-written')).toBeNull()
  })

  it('returns null (not a crash) for corrupt JSON', () => {
    localStorage.setItem('pabrik-git-status:v1:/repo/corrupt', '{not json')
    expect(readGitStatusCache('/repo/corrupt')).toBeNull()
  })

  it('returns null for a payload without is_git_repo', () => {
    localStorage.setItem('pabrik-git-status:v1:/repo/foreign', JSON.stringify({ foo: 'bar' }))
    expect(readGitStatusCache('/repo/foreign')).toBeNull()
  })

  it('normalizes wire nulls to the declared GitStatus strings', () => {
    // The backend's GitStatusResponse declares branch/status as ?[]const u8
    // — a detached non-repo payload may carry nulls. ChatView renders
    // `branch || 'detached'`, so empty string is equivalent and typed.
    localStorage.setItem(
      'pabrik-git-status:v1:/repo/nulls',
      JSON.stringify({ is_git_repo: false, branch: null, status: null, has_changes: false }),
    )
    expect(readGitStatusCache('/repo/nulls')).toEqual({
      is_git_repo: false,
      branch: '',
      has_changes: false,
      is_clean: true,
      current: '',
      status: '',
    })
  })

  it('ignores empty cwd instead of writing a degenerate key', () => {
    writeGitStatusCache('', STATUS)
    expect(readGitStatusCache('')).toBeNull()
  })

  it('clearGitStatusCache drops only the given cwd', () => {
    writeGitStatusCache('/repo/a', STATUS)
    writeGitStatusCache('/repo/b', STATUS)
    clearGitStatusCache('/repo/a')
    expect(readGitStatusCache('/repo/a')).toBeNull()
    expect(readGitStatusCache('/repo/b')).toEqual(STATUS)
  })

  it('stays silent when storage throws (private mode / quota)', () => {
    const broken = {
      getItem: () => {
        throw new Error('denied')
      },
      setItem: () => {
        throw new Error('quota')
      },
      removeItem: () => {
        throw new Error('denied')
      },
    }
    // Cast via unknown: the stub only implements the three methods the
    // helper touches, which intentionally overlap Storage only partially.
    vi.stubGlobal('localStorage', broken as unknown as Storage)
    expect(() => writeGitStatusCache('/repo/a', STATUS)).not.toThrow()
    expect(readGitStatusCache('/repo/a')).toBeNull()
    expect(() => clearGitStatusCache('/repo/a')).not.toThrow()
  })
})
