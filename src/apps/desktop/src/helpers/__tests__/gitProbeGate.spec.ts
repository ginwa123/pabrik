import { beforeEach, describe, expect, it } from 'vitest'

import {
  GIT_PROBE_COOLDOWN_MS,
  GIT_PROBE_FAILURE_LIMIT,
  clearGitProbeGate,
  forgetGitProbe,
  gitProbeAnswer,
  mayProbeGit,
  recordGitAnswer,
  recordGitFailure,
} from '../gitProbeGate'

const CWD = '/work/repo'
const NOW = 1_700_000_000_000
const HOUR = 60 * 60_000

describe('git probe gate', () => {
  beforeEach(() => {
    clearGitProbeGate()
  })

  it('asks about a folder it has never heard from', () => {
    expect(mayProbeGit(CWD, NOW)).toBe(true)
    expect(gitProbeAnswer(CWD)).toBeNull()
  })

  it('stops asking a folder that answered it holds no repository', () => {
    recordGitAnswer(CWD, false)

    expect(mayProbeGit(CWD, NOW)).toBe(false)
    expect(mayProbeGit(CWD, NOW + 24 * HOUR)).toBe(false)
    expect(gitProbeAnswer(CWD)).toBe('no-repo')
  })

  it('keeps asking a repository, because its branch moves', () => {
    recordGitAnswer(CWD, true)

    expect(mayProbeGit(CWD, NOW)).toBe(true)
    expect(mayProbeGit(CWD, NOW + 24 * HOUR)).toBe(true)
    expect(gitProbeAnswer(CWD)).toBe('repo')
  })

  it('keeps asking after one failure, so a single blip does not silence git', () => {
    recordGitFailure(CWD, NOW)

    expect(mayProbeGit(CWD, NOW)).toBe(true)
    expect(gitProbeAnswer(CWD)).toBeNull()
  })

  it('leaves a folder alone once its endpoint keeps failing, and tries again after the cooldown', () => {
    for (let attempt = 0; attempt < GIT_PROBE_FAILURE_LIMIT; attempt++) recordGitFailure(CWD, NOW)

    expect(mayProbeGit(CWD, NOW)).toBe(false)
    expect(mayProbeGit(CWD, NOW + GIT_PROBE_COOLDOWN_MS - 1)).toBe(false)
    expect(mayProbeGit(CWD, NOW + GIT_PROBE_COOLDOWN_MS)).toBe(true)
  })

  it('an answer ends the failure streak', () => {
    recordGitFailure(CWD, NOW)
    recordGitFailure(CWD, NOW)
    recordGitAnswer(CWD, true)
    recordGitFailure(CWD, NOW)

    expect(mayProbeGit(CWD, NOW)).toBe(true)
  })

  it('a refresh makes a silent folder askable again', () => {
    recordGitAnswer(CWD, false)

    forgetGitProbe(CWD)

    expect(mayProbeGit(CWD, NOW)).toBe(true)
    expect(gitProbeAnswer(CWD)).toBeNull()
  })

  it('remembers each folder on its own', () => {
    recordGitAnswer('/work/one', false)

    expect(mayProbeGit('/work/two', NOW)).toBe(true)
  })

  it('never gates an empty path', () => {
    recordGitAnswer('', false)
    recordGitFailure('', NOW)

    expect(mayProbeGit('', NOW)).toBe(true)
  })
})
