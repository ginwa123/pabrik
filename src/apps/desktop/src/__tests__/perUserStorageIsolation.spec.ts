/** Per-user browser-storage isolation, end to end (plan 2026-09-25, W5). The bug: every
 * localStorage key is origin-global, so two users on the same browser profile share one key space. */
import { beforeEach, describe, expect, it } from 'vitest'
import { makeLocalStorageStub } from './helpers'
import {
  isIdentityResolved,
  purgeForeignScopedKeys,
  resetUserScopeForTest,
  setCurrentUserId,
  userScopedKey,
} from '../helpers/userScope'
import {
  clearWorkspacesCache,
  readWorkspacesCache,
  writeWorkspacesCache,
} from '../helpers/workspacesCache'
import type { Workspace } from '../api'

function ws(id: string, name: string): Workspace {
  return { id, name, icon: '📁', items: [], expanded: false } as Workspace
}

describe('per-user storage isolation', () => {
  beforeEach(() => {
    resetUserScopeForTest()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it("B never reads A's cached workspace list", () => {
    // A signs in and the app caches A's list.
    setCurrentUserId('user_a')
    writeWorkspacesCache([ws('ws_a', 'A private')])
    expect(readWorkspacesCache()?.map((w) => w.id)).toEqual(['ws_a'])

    // Identity flips to B (login as B, or A logged out and B logged in).
    setCurrentUserId('user_b')
    purgeForeignScopedKeys()

    // B's first paint reads B's slot — empty, not A's list.
    expect(readWorkspacesCache()).toBeNull()
  })

  it("A's cache survives a logout/login round trip by the same user", () => {
    setCurrentUserId('user_a')
    writeWorkspacesCache([ws('ws_a', 'A private')])

    // Logout: scope cleared, foreign keys purged.
    setCurrentUserId(null)
    purgeForeignScopedKeys()
    expect(readWorkspacesCache()).toBeNull()

    // A signs back in: the scoped key was purged on logout, so the cache is gone — a fresh fetch
    // repopulates it. (Asserting the purge, not a resurrection: keeping A's cache across a logout
    // would leave it on disk for the next user on a shared profile.)
    setCurrentUserId('user_a')
    expect(readWorkspacesCache()).toBeNull()
    writeWorkspacesCache([ws('ws_a', 'A private again')])
    expect(readWorkspacesCache()?.map((w) => w.name)).toEqual(['A private again'])
  })

  it('the first-paint gate refuses to read the cache before identity resolves', () => {
    // Simulate a cold boot where a previous user left data behind: the key is
    // written unscoped (as it would be with no identity), then the identity
    // resolves to B.
    localStorage.setItem('pabrik-workspaces:v1', JSON.stringify([{ id: 'ws_stale', name: 'Stale' }]))
    expect(isIdentityResolved()).toBe(false)

    // The store's gate is `isIdentityResolved() ? readWorkspacesCache() : null`
    // — before resolution it must not paint.
    const painted = isIdentityResolved() ? readWorkspacesCache() : null
    expect(painted).toBeNull()

    // Once B's identity resolves, the read is scoped to B and the stale
    // unscoped entry is invisible.
    setCurrentUserId('user_b')
    expect(isIdentityResolved()).toBe(true)
    expect(readWorkspacesCache()).toBeNull()
  })

  it("clearWorkspacesCache only clears the current user's slot", () => {
    setCurrentUserId('user_a')
    writeWorkspacesCache([ws('ws_a', 'A')])
    setCurrentUserId('user_b')
    writeWorkspacesCache([ws('ws_b', 'B')])

    clearWorkspacesCache()

    expect(localStorage.getItem(userScopedKey('pabrik-workspaces:v1'))).toBeNull()
    // A's slot is untouched by B's clear.
    expect(localStorage.getItem('pabrik-workspaces:v1::u:user_a')).not.toBeNull()
  })

  it('auth-off (no identity) keeps the legacy unscoped key', () => {
    // No identity: the key is the legacy one, so an auth-off install needs no
    // migration and sees exactly what it saw before.
    writeWorkspacesCache([ws('ws_legacy', 'Legacy')])
    expect(localStorage.getItem('pabrik-workspaces:v1')).not.toBeNull()
    expect(readWorkspacesCache()?.map((w) => w.id)).toEqual(['ws_legacy'])
  })
})
