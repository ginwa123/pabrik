/** GitLab (merge request) behaviour for the PR surface. */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import {
  branchUrlFromPrUrl,
  clearPrStatusCache,
  fetchPrConflictCached,
  fetchPrInfoCached,
  isPrConflictValue,
  providerFromPrUrl,
  repoBaseFromPrUrl,
} from '../prStatusCache'
import { conflictsUrl, forgeFromPrUrl, forgeWording } from '../forgeWording'
import * as api from '../../api'

const GH_URL = 'https://github.com/acme/app/pull/42'
const MR_URL = 'https://gitlab.com/group/sub/repo/-/merge_requests/7'

describe('providerFromPrUrl', () => {
  it('recognises both forges and neither', () => {
    expect(providerFromPrUrl(GH_URL)).toBe('github')
    expect(providerFromPrUrl(MR_URL)).toBe('gitlab')
    expect(providerFromPrUrl('')).toBe('')
    expect(providerFromPrUrl('https://git.corp.example.com/a/b/changes/9')).toBe('')
  })
})

describe('repoBaseFromPrUrl', () => {
  it('keeps working for GitHub', () => {
    expect(repoBaseFromPrUrl(GH_URL)).toBe('https://github.com/acme/app')
  })

  it('returns the repo for a GitLab MR, subgroups included', () => {
    // THE regression: this returned '' before, because only '/pull/' was
    // recognised. That silently disabled GitBranchMenu's branch link.
    expect(repoBaseFromPrUrl(MR_URL)).toBe('https://gitlab.com/group/sub/repo')
  })

  it('stops at the change-request segment even on a deeply nested group', () => {
    expect(repoBaseFromPrUrl('https://gitlab.com/a/b/c/d/repo/-/merge_requests/11')).toBe(
      'https://gitlab.com/a/b/c/d/repo',
    )
  })

  it('returns empty for a non-change-request URL', () => {
    expect(repoBaseFromPrUrl('')).toBe('')
    expect(repoBaseFromPrUrl('https://github.com/acme/app')).toBe('')
  })
})

describe('branchUrlFromPrUrl', () => {
  it('builds the GitHub /tree/ shape for GitHub', () => {
    expect(branchUrlFromPrUrl(GH_URL, 'feature/x')).toBe(
      'https://github.com/acme/app/tree/feature%2Fx',
    )
  })

  it('builds the GitLab /-/tree/ shape for GitLab', () => {
    // '/-/tree/' — a GitHub-shaped link on a GitLab repo 404s.
    expect(branchUrlFromPrUrl(MR_URL, 'feature/x')).toBe(
      'https://gitlab.com/group/sub/repo/-/tree/feature%2Fx',
    )
  })

  it('is empty without a PR URL or a branch', () => {
    expect(branchUrlFromPrUrl('', 'feature/x')).toBe('')
    expect(branchUrlFromPrUrl(MR_URL, '')).toBe('')
  })
})

describe('forgeWording', () => {
  it('uses GitHub vocabulary by default and for github', () => {
    // '' is what every session stored before GitLab support existed, and
    // all of those are GitHub — defaulting keeps them correct.
    for (const p of [undefined, null, '', 'github', 'nonsense']) {
      const w = forgeWording(p)
      expect(w.short).toBe('PR')
      expect(w.noun).toBe('pull request')
      expect(w.forge).toBe('GitHub')
    }
  })

  it('uses merge-request vocabulary for gitlab', () => {
    const w = forgeWording('gitlab')
    expect(w.short).toBe('MR')
    expect(w.noun).toBe('merge request')
    expect(w.label).toBe('Merge request')
    expect(w.forge).toBe('GitLab')
  })

  it('carries the CLI program so error text names the tool that ran', () => {
    // CreatePrDialog interpolates `forge.program` into its failure
    // message. The field was missing once and only `vue-tsc --build`
    // (the CI command) caught it — pin it here so the table stays whole.
    expect(forgeWording('github').program).toBe('gh')
    expect(forgeWording('gitlab').program).toBe('glab')
    expect(forgeWording('').program).toBe('gh')
  })

  it('detects the forge from a URL when no provider was ever stored', () => {
    expect(forgeFromPrUrl(MR_URL).short).toBe('MR')
    expect(forgeFromPrUrl(GH_URL).short).toBe('PR')
    expect(forgeFromPrUrl(undefined).short).toBe('PR')
  })
})

describe('conflictsUrl', () => {
  it('returns the GitHub /conflicts link', () => {
    expect(conflictsUrl('github', GH_URL)).toBe(`${GH_URL}/conflicts`)
  })

  it('returns empty for GitLab, which has no such route', () => {
    // Building one anyway yields a link that looks live and 404s.
    expect(conflictsUrl('gitlab', MR_URL)).toBe('')
  })

  it('tolerates a trailing slash and an empty URL', () => {
    expect(conflictsUrl('github', `${GH_URL}/`)).toBe(`${GH_URL}/conflicts`)
    expect(conflictsUrl('github', '')).toBe('')
    expect(conflictsUrl('gitlab', '')).toBe('')
  })
})

describe('isPrConflictValue', () => {
  it('knows the GitHub vocabulary (unchanged)', () => {
    expect(isPrConflictValue('CONFLICTING', '')).toBe(true)
    expect(isPrConflictValue('', 'DIRTY')).toBe(true)
    expect(isPrConflictValue('MERGEABLE', 'CLEAN')).toBe(false)
  })

  it('knows the GitLab detailed_merge_status vocabulary', () => {
    expect(isPrConflictValue('conflicted', '')).toBe(true)
    expect(isPrConflictValue('not_mergeable', '')).toBe(true)
    expect(isPrConflictValue('mergeable', 'can_be_merged')).toBe(false)
  })

  it('is quiet for unknown/empty values', () => {
    expect(isPrConflictValue('', '')).toBe(false)
    expect(isPrConflictValue('UNKNOWN', 'UNKNOWN')).toBe(false)
  })
})

describe('prStatusCache provider plumbing', () => {
  beforeEach(() => {
    clearPrStatusCache()
    vi.restoreAllMocks()
  })

  it('forwards the provider to getPrStatus', async () => {
    const spy = vi
      .spyOn(api, 'getPrStatus')
      .mockResolvedValue({ status: 'open', pr_url: MR_URL } as never)

    await fetchPrInfoCached('/repo', 'feature-x', 'gitlab')

    expect(spy).toHaveBeenCalledWith('/repo', 'feature-x', { provider: 'gitlab' })
  })

  it('omits the provider when unknown, so the backend can sniff the remote', async () => {
    const spy = vi
      .spyOn(api, 'getPrStatus')
      .mockResolvedValue({ status: 'open', pr_url: GH_URL } as never)

    await fetchPrInfoCached('/repo', 'feature-x')

    // `undefined`, not '': the backend treats an empty provider as
    // "detect from origin remote", which is the accurate answer here.
    expect(spy).toHaveBeenCalledWith('/repo', 'feature-x', { provider: undefined })
  })

  it('keys the cache by provider so gitlab never serves a github answer', async () => {
    const spy = vi
      .spyOn(api, 'getPrStatus')
      .mockImplementation(
        async (_c: string, _b: string, opts?: { provider?: string }) =>
          (opts?.provider === 'gitlab'
            ? { status: 'open', pr_url: MR_URL, mergeable: 'conflicted' }
            : { status: 'merged', pr_url: GH_URL, mergeable: 'MERGEABLE' }) as never,
      )

    const [gh, gl] = await Promise.all([
      fetchPrInfoCached('/repo', 'same-branch', 'github'),
      fetchPrInfoCached('/repo', 'same-branch', 'gitlab'),
    ])

    // Same repo + same branch, different forge → two separate answers.
    expect(gh.status).toBe('merged')
    expect(gl.status).toBe('open')
    expect(gl.prUrl).toBe(MR_URL)
    expect(isPrConflictValue(gl.mergeable, gl.merge_state)).toBe(true)
    expect(spy).toHaveBeenCalledTimes(2)

    // A second GitLab read is served from cache, not a third spawn.
    await fetchPrConflictCached('/repo', 'same-branch', 'gitlab')
    expect(spy).toHaveBeenCalledTimes(2)
  })

  it('flags a GitLab conflicted MR as a conflict', async () => {
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      pr_url: MR_URL,
      mergeable: 'conflicted',
      merge_state: 'not_mergeable',
    } as never)

    await expect(fetchPrConflictCached('/repo', 'b', 'gitlab')).resolves.toBe(true)
  })
})
