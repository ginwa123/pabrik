/** Whole-file reader: the cache/dedupe contract that makes "Whole file" cost one request per file
 * instead of one per click. Two properties matter more than the rest, and both are about being
 * WRONG in the safe direction: - a backend failure REJECTS. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  clearWholeFileDiffCache,
  fetchWholeFileDiff,
  readWholeFileDiff,
  wholeFileKey,
} from '../chat_right_sidebar/wholeFileDiff'
import * as api from '../../../api'

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, getGitWholeFileDiff: vi.fn() }
})

const DIFF = [
  'diff --git a/x.go b/x.go',
  '--- a/x.go',
  '+++ b/x.go',
  '@@ -1,2 +1,2 @@',
  ' keep',
  '-old',
  '+new',
  '',
].join('\n')

function respond(content = DIFF, extra: Record<string, unknown> = {}) {
  vi.mocked(api.getGitWholeFileDiff).mockResolvedValue({
    diffs: [{ path: 'x.go', staged: false, diff_content: content }],
    ...extra,
  } as never)
}

beforeEach(() => {
  clearWholeFileDiffCache()
  vi.mocked(api.getGitWholeFileDiff).mockReset()
})

describe('wholeFileDiff', () => {
  it('keys staged and unstaged separately — the same path has two diffs', () => {
    expect(wholeFileKey('x.go', false)).not.toBe(wholeFileKey('x.go', true))
  })

  it('parses the full-context diff into the same ParsedDiffLine shape the hunks use', async () => {
    respond()
    const result = await fetchWholeFileDiff('/repo', 'x.go', false)
    expect(result.refused).toBe(false)
    expect(result.added).toBe(1)
    expect(result.removed).toBe(1)
    expect(result.lines.map((l) => l.type)).toContain('add')
    expect(readWholeFileDiff('/repo', 'x.go', false)).toBe(result)
  })

  it('fetches ONCE for repeated reads of the same file', async () => {
    respond()
    const [a, b] = await Promise.all([
      fetchWholeFileDiff('/repo', 'x.go', false),
      fetchWholeFileDiff('/repo', 'x.go', false),
    ])
    expect(api.getGitWholeFileDiff).toHaveBeenCalledTimes(1)
    expect(a).toBe(b)

    await fetchWholeFileDiff('/repo', 'x.go', false)
    expect(api.getGitWholeFileDiff).toHaveBeenCalledTimes(1)
  })

  it('REJECTS on a backend failure and does not cache the failure', async () => {
    vi.mocked(api.getGitWholeFileDiff).mockRejectedValueOnce(new Error('offline'))
    await expect(fetchWholeFileDiff('/repo', 'x.go', false)).rejects.toThrow('offline')
    expect(readWholeFileDiff('/repo', 'x.go', false)).toBeNull()

    // A failed fetch must not wedge the next attempt.
    respond()
    const ok = await fetchWholeFileDiff('/repo', 'x.go', false)
    expect(ok.refused).toBe(false)
    expect(api.getGitWholeFileDiff).toHaveBeenCalledTimes(2)
  })

  it('reports a refusal as refused — with NO lines, never as an empty-but-valid file', async () => {
    respond('', { whole_file_refused: true })
    const result = await fetchWholeFileDiff('/repo', 'x.go', false)
    expect(result.refused).toBe(true)
    expect(result.lines).toEqual([])
    expect(result.added).toBe(0)
  })

  it('treats a response that omits the requested path as refused, not as a clean file', async () => {
    vi.mocked(api.getGitWholeFileDiff).mockResolvedValue({
      diffs: [],
    } as never)
    const result = await fetchWholeFileDiff('/repo', 'x.go', false)
    expect(result.refused).toBe(true)
    expect(result.lines).toEqual([])
  })

  it('scopes the cache by cwd', async () => {
    respond()
    await fetchWholeFileDiff('/repo-a', 'x.go', false)
    expect(readWholeFileDiff('/repo-b', 'x.go', false)).toBeNull()
    await fetchWholeFileDiff('/repo-b', 'x.go', false)
    expect(api.getGitWholeFileDiff).toHaveBeenCalledTimes(2)
  })
})
