/** Per-user browser-storage namespacing (plan 2026-09-25, W5). The bug these specs pin: every
 * localStorage key is origin-global, so two users on the same browser profile share one key space
 * and B inherits A's cached workspace list / active chat / open tabs. */
import { beforeEach, describe, expect, it } from 'vitest'
import { makeLocalStorageStub } from './helpers'
import {
  getCurrentUserId,
  isForeignScopedKey,
  isIdentityResolved,
  purgeForeignScopedKeys,
  resetUserScopeForTest,
  setCurrentUserId,
  userIdFromScopedKey,
  userScopedKey,
} from '../helpers/userScope'

describe('userScopedKey', () => {
  beforeEach(() => {
    resetUserScopeForTest()
    // jsdom 29 dropped localStorage from the default globals — install the
    // repo's Map-backed stub (see __tests__/helpers.ts).
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('returns the key unchanged when there is no identity (auth off)', () => {
    // No identity => unscoped => the auth-off path needs no migration.
    expect(userScopedKey('pabrik-workspaces:v1')).toBe('pabrik-workspaces:v1')
  })

  it('namespaces the key by user id once an identity is set', () => {
    setCurrentUserId('user_a')
    expect(userScopedKey('pabrik-workspaces:v1')).toBe('pabrik-workspaces:v1::u:user_a')
  })

  it('gives two users different physical keys for the same logical key', () => {
    setCurrentUserId('user_a')
    const a = userScopedKey('active-chat-id')
    setCurrentUserId('user_b')
    const b = userScopedKey('active-chat-id')
    expect(a).not.toBe(b)
    expect(a).toBe('active-chat-id::u:user_a')
    expect(b).toBe('active-chat-id::u:user_b')
  })

  it('treats an empty string as no identity', () => {
    setCurrentUserId('')
    expect(userScopedKey('active-chat-id')).toBe('active-chat-id')
    expect(getCurrentUserId()).toBeNull()
  })

  it('round-trips the user id out of a scoped key', () => {
    setCurrentUserId('user_a')
    const scoped = userScopedKey('pabrik-tabs:v1:win1')
    expect(userIdFromScopedKey(scoped)).toBe('user_a')
    expect(userIdFromScopedKey('pabrik-tabs:v1:win1')).toBeNull()
  })

  it('marks a key from another user as foreign', () => {
    setCurrentUserId('user_a')
    expect(isForeignScopedKey('active-chat-id::u:user_b')).toBe(true)
    expect(isForeignScopedKey('active-chat-id::u:user_a')).toBe(false)
    // Unscoped keys are never foreign — they are the auth-off key space.
    expect(isForeignScopedKey('active-chat-id')).toBe(false)
  })

  it('reports whether the identity has been resolved', () => {
    expect(isIdentityResolved()).toBe(false)
    setCurrentUserId('user_a')
    expect(isIdentityResolved()).toBe(true)
  })
})

describe('purgeForeignScopedKeys', () => {
  beforeEach(() => {
    resetUserScopeForTest()
    // jsdom 29 dropped localStorage from the default globals — install the
    // repo's Map-backed stub (see __tests__/helpers.ts).
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it("removes the previous user's scoped keys and keeps the current user's", () => {
    // A was signed in and cached data.
    setCurrentUserId('user_a')
    localStorage.setItem(userScopedKey('pabrik-workspaces:v1'), '["A private"]')
    localStorage.setItem(userScopedKey('active-chat-id'), 'chat-a')

    // B signs in: the scope flips, then the purge runs.
    setCurrentUserId('user_b')
    localStorage.setItem(userScopedKey('pabrik-workspaces:v1'), '["B private"]')
    const removed = purgeForeignScopedKeys()

    expect(removed).toBe(2)
    expect(localStorage.getItem('pabrik-workspaces:v1::u:user_a')).toBeNull()
    expect(localStorage.getItem('active-chat-id::u:user_a')).toBeNull()
    // B's own cache survives.
    expect(localStorage.getItem('pabrik-workspaces:v1::u:user_b')).toBe('["B private"]')
  })

  it('never touches unscoped keys or the auth cache', () => {
    localStorage.setItem('sidebar-width', '280')
    localStorage.setItem('pabrik-auth-me:v1', '{"status":200}')
    setCurrentUserId('user_a')
    localStorage.setItem(userScopedKey('active-chat-id'), 'chat-a')

    setCurrentUserId('user_b')
    purgeForeignScopedKeys()

    expect(localStorage.getItem('sidebar-width')).toBe('280')
    expect(localStorage.getItem('pabrik-auth-me:v1')).toBe('{"status":200}')
  })

  it('purges every scoped key when the identity is cleared (logout)', () => {
    setCurrentUserId('user_a')
    localStorage.setItem(userScopedKey('pabrik-workspaces:v1'), '["A"]')
    localStorage.setItem(userScopedKey('pabrik-tabs:v1:win1'), '[]')

    setCurrentUserId(null)
    const removed = purgeForeignScopedKeys()

    expect(removed).toBe(2)
    expect(localStorage.getItem('pabrik-workspaces:v1::u:user_a')).toBeNull()
    expect(localStorage.getItem('pabrik-tabs:v1:win1::u:user_a')).toBeNull()
  })

  it('is a no-op when there is nothing foreign', () => {
    setCurrentUserId('user_a')
    localStorage.setItem(userScopedKey('active-chat-id'), 'chat-a')
    expect(purgeForeignScopedKeys()).toBe(0)
    expect(localStorage.getItem('active-chat-id::u:user_a')).toBe('chat-a')
  })
})
