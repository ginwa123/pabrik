import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { getGitChanges, getGitStatus, type GitChangesResponse, type GitStatus } from '@/api/index'
import { clearGitStatusCache } from '@/helpers/gitStatusCache'
import { GIT_PROBE_FAILURE_LIMIT, clearGitProbeGate, forgetGitProbe } from '@/helpers/gitProbeGate'

const CWD = '/tmp/git-probe-wire-spec'

const REPO: GitStatus = {
  is_git_repo: true,
  branch: 'main',
  has_changes: false,
  is_clean: true,
  current: 'main',
  status: 'clean',
}

const NO_REPO: GitStatus = {
  is_git_repo: false,
  branch: '',
  has_changes: false,
  is_clean: true,
  current: '',
  status: '',
}

const NO_CHANGES: GitChangesResponse = {
  is_git_repo: false,
  branch: null,
  has_changes: false,
  staged_files: [],
  modified_files: [],
  untracked_files: [],
}

type Answer = { status: number; body: unknown }

function fakeGitServer(answer: (url: string) => Answer): string[] {
  const asked: string[] = []
  vi.stubGlobal('fetch', (input: RequestInfo | URL) => {
    const url = String(input)
    asked.push(url)
    const reply = answer(url)
    return Promise.resolve(
      new Response(JSON.stringify(reply.body), {
        status: reply.status,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
  })
  return asked
}

describe('git endpoints and a folder that cannot answer git', () => {
  beforeEach(() => {
    clearGitProbeGate()
    clearGitStatusCache(CWD)
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    clearGitStatusCache(CWD)
    clearGitProbeGate()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('asks a git-less folder once, then answers from what it learned', async () => {
    const asked = fakeGitServer(() => ({ status: 200, body: NO_REPO }))

    const first = await getGitStatus(CWD)
    const second = await getGitStatus(CWD)

    expect(asked).toHaveLength(1)
    expect(first).toEqual(NO_REPO)
    expect(second).toEqual(NO_REPO)
  })

  it('asks a repository on every read, and answers with the fresh branch', async () => {
    let branch = 'main'
    const asked = fakeGitServer(() => ({ status: 200, body: { ...REPO, branch } }))

    const first = await getGitStatus(CWD)
    branch = 'feature'
    const second = await getGitStatus(CWD)

    expect(asked).toHaveLength(2)
    expect(first.branch).toBe('main')
    expect(second.branch).toBe('feature')
  })

  it('asks again when the user refreshes a git-less folder', async () => {
    const asked = fakeGitServer(() => ({ status: 200, body: NO_REPO }))
    await getGitStatus(CWD)

    forgetGitProbe(CWD)
    await getGitStatus(CWD)

    expect(asked).toHaveLength(2)
  })

  it('keeps asking after one failed read, so a blip does not silence git', async () => {
    let calls = 0
    const asked = fakeGitServer(() => {
      calls++
      return calls === 1 ? { status: 500, body: { error: 'boom' } } : { status: 200, body: REPO }
    })

    await getGitStatus(CWD)
    const second = await getGitStatus(CWD)

    expect(asked).toHaveLength(2)
    expect(second.branch).toBe('main')
  })

  it('stops asking an endpoint that keeps failing', async () => {
    const asked = fakeGitServer(() => ({ status: 500, body: { error: 'GuestWorkspaceUnknown' } }))

    for (let attempt = 0; attempt < GIT_PROBE_FAILURE_LIMIT; attempt++) await getGitStatus(CWD)
    const afterTheLimit = await getGitStatus(CWD)

    expect(asked).toHaveLength(GIT_PROBE_FAILURE_LIMIT)
    expect(afterTheLimit.is_git_repo).toBe(false)
    expect(afterTheLimit.status).toBe('error')
  })

  it('spends one request when the status read already learned the folder is no repository', async () => {
    const asked = fakeGitServer((url) =>
      url.includes('/git/status') ? { status: 200, body: NO_REPO } : { status: 200, body: NO_CHANGES },
    )

    await getGitStatus(CWD)
    const changes = await getGitChanges(CWD)

    expect(asked).toHaveLength(1)
    expect(changes.is_git_repo).toBe(false)
    expect(changes.staged_files).toEqual([])
  })

  it('learns the folder is no repository from the changes read alone', async () => {
    const asked = fakeGitServer(() => ({ status: 200, body: NO_CHANGES }))

    await getGitChanges(CWD)
    const status = await getGitStatus(CWD)

    expect(asked).toHaveLength(1)
    expect(status.is_git_repo).toBe(false)
    expect(status.status).toBe('')
  })
})
