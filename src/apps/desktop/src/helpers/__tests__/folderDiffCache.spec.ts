/**  * Shared folder-diff snapshot — the module every frontend diff read goes through. These tests
 * assert the properties that stop the request flood: a click is free, concurrent readers share one
 * request, and a dead backend surfaces as a rejection rather than a diff that looks clean. */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import {
  clearFolderDiffCache,
  fetchFolderDiff,
  folderDiffKey,
  hasFreshFolderSnapshot,
  primeFolderDiffs,
  readFolderDiff,
  FOLDER_DIFF_TTL_MS,
} from '../folderDiffCache'

const { getGitFolderDiffsMock } = vi.hoisted(() => ({ getGitFolderDiffsMock: vi.fn() }))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return { ...actual, getGitFolderDiffs: getGitFolderDiffsMock }
})

const diffFor = (path: string, staged = false) => ({
  path,
  diff_content: `+${path}${staged ? ':staged' : ''}`,
  staged,
})

describe('folderDiffCache', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearFolderDiffCache()
  })

  it('keys by BOTH path and side — the same file has two independent diffs', () => {
    primeFolderDiffs('/repo', [diffFor('a.txt'), diffFor('a.txt', true)])
    expect(readFolderDiff('/repo', 'a.txt', false)?.diff_content).toBe('+a.txt')
    expect(readFolderDiff('/repo', 'a.txt', true)?.diff_content).toBe('+a.txt:staged')
    expect(folderDiffKey(true, 'a.txt')).not.toBe(folderDiffKey(false, 'a.txt'))
  })

  it('serves a primed snapshot without any request', async () => {
    primeFolderDiffs('/repo', [diffFor('a.txt')])
    expect(hasFreshFolderSnapshot('/repo')).toBe(true)
    const got = await fetchFolderDiff('/repo', 'a.txt', false)
    expect(got.diff_content).toBe('+a.txt')
    expect(getGitFolderDiffsMock).not.toHaveBeenCalled()
  })

  it('a path the server did not report is an EMPTY diff, not an error', async () => {
    // The server only reports CHANGED paths. A clean file used to come back
    // from the per-file endpoint as empty content, so callers must still get
    // that — otherwise every unchanged file renders as a failure.
    primeFolderDiffs('/repo', [diffFor('a.txt')])
    const got = await fetchFolderDiff('/repo', 'untouched.txt', false)
    expect(got).toEqual({ path: 'untouched.txt', diff_content: '', staged: false })
    expect(getGitFolderDiffsMock).not.toHaveBeenCalled()
  })

  it('one request serves every concurrent reader of the same cwd', async () => {
    let release: (v: { diffs: unknown[] }) => void = () => {}
    getGitFolderDiffsMock.mockReturnValue(
      new Promise((res) => {
        release = res as typeof release
      }),
    )
    const a = fetchFolderDiff('/repo', 'a.txt', false)
    const b = fetchFolderDiff('/repo', 'b.txt', false)
    const c = fetchFolderDiff('/repo', 'a.txt', true)
    release({ diffs: [diffFor('a.txt'), diffFor('b.txt'), diffFor('a.txt', true)] })

    const [ra, rb, rc] = await Promise.all([a, b, c])
    // The whole point: three readers, ONE request.
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    expect(ra.diff_content).toBe('+a.txt')
    expect(rb.diff_content).toBe('+b.txt')
    expect(rc.diff_content).toBe('+a.txt:staged')
  })

  it('a second read after a settle is served from the snapshot', async () => {
    getGitFolderDiffsMock.mockResolvedValue({ diffs: [diffFor('a.txt')] })
    await fetchFolderDiff('/repo', 'a.txt', false)
    await fetchFolderDiff('/repo', 'a.txt', false)
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
  })

  it('rejects when the backend fails — it must not look like "no changes"', async () => {
    getGitFolderDiffsMock.mockRejectedValue(new Error('backend down'))
    // An outage swallowed into an empty diff reads in the UI as "this file is
    // unchanged", which is the worst direction to be wrong in.
    await expect(fetchFolderDiff('/repo', 'a.txt', false)).rejects.toThrow('backend down')
  })

  it('a failed fetch does not poison the next attempt', async () => {
    getGitFolderDiffsMock.mockRejectedValueOnce(new Error('flaky'))
    await expect(fetchFolderDiff('/repo', 'a.txt', false)).rejects.toThrow('flaky')
    getGitFolderDiffsMock.mockResolvedValue({ diffs: [diffFor('a.txt')] })
    const got = await fetchFolderDiff('/repo', 'a.txt', false)
    expect(got.diff_content).toBe('+a.txt')
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(2)
  })

  it('an expired snapshot is not served', async () => {
    vi.useFakeTimers()
    try {
      primeFolderDiffs('/repo', [diffFor('a.txt')])
      expect(readFolderDiff('/repo', 'a.txt', false)).not.toBeNull()
      // One tick past the TTL: the agent has been writing since the snapshot.
      vi.advanceTimersByTime(FOLDER_DIFF_TTL_MS + 1)
      expect(readFolderDiff('/repo', 'a.txt', false)).toBeNull()
      expect(hasFreshFolderSnapshot('/repo')).toBe(false)

      getGitFolderDiffsMock.mockResolvedValue({ diffs: [diffFor('a.txt')] })
      await fetchFolderDiff('/repo', 'a.txt', false)
      expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('snapshots do not leak across cwds', () => {
    primeFolderDiffs('/repo-a', [diffFor('a.txt')])
    expect(readFolderDiff('/repo-b', 'a.txt', false)).toBeNull()
    expect(readFolderDiff('/repo-a', 'a.txt', false)).not.toBeNull()
  })
})
