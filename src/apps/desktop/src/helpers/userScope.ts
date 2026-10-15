/**
 * Per-user browser-storage namespacing (plan 2026-09-25, W5).
 *
 * Every localStorage / IndexedDB key in the app is origin-global: two users
 * signing in on the same browser profile share one key space, so B inherits
 * A's cached workspace list, active chat, open tabs, task media and diff
 * comments — and logout clears none of it. This module is the single place
 * that turns a logical key into a per-user physical key.
 *
 * Contract:
 * - `userScopedKey(key)` returns the key unchanged when there is no identity
 *   (auth off, or `/api/auth/me` not resolved yet) — so the auth-off path is
 *   byte-identical and needs no migration.
 * - With an identity it returns `key::u:<userId>`.
 * - The identity is cached in module memory and refreshed from
 *   `getAuthMeCached()`; `setCurrentUserId` is the synchronous setter used by
 *   the auth flow (login / logout / identity change) so a caller never has to
 *   await before reading a key.
 *
 * Why a suffix and not a prefix: existing keys are already namespaced by
 * feature (`pabrik-workspaces:v1`, `active-chat-id`), and a suffix keeps the
 * feature prefix readable in devtools while making the user boundary
 * unambiguous. It also means a legacy (unscoped) key can never collide with a
 * scoped one.
 */

import { getAuthMeCached } from './authMe'

/** Separator between the logical key and the user id. */
const USER_SUFFIX = '::u:'

/** The identity currently in effect. `null` means "no identity" — auth off, or
 * `/api/auth/me` has not resolved yet — and `userScopedKey` then returns the
 * key unchanged. */
let currentUserId: string | null = null

/** True once `refreshCurrentUserId` has completed at least once. */
let resolved = false

/** Synchronously set the identity. Called by the auth flow on login, logout,
 * and whenever `/api/auth/me` reports a different id. Passing `null` (or an
 * empty string) means "no identity" and disables scoping. */
export function setCurrentUserId(userId: string | null | undefined): void {
  currentUserId = userId && userId.length > 0 ? userId : null
  resolved = true
}

/** The identity currently in effect, or null when there is none. */
export function getCurrentUserId(): string | null {
  return currentUserId
}

/** True once the identity has been resolved at least once this page load. */
export function isIdentityResolved(): boolean {
  return resolved
}

/** Resolve the identity from the cached `/api/auth/me` and store it.
 * Returns the id (or null). Fail-silent: a network error leaves the previous
 * value in place, because a transient `/me` failure must not silently switch
 * the app to the unscoped key space (that would paint the previous user's
 * cache under the new user's session). */
export async function refreshCurrentUserId(): Promise<string | null> {
  try {
    const { data } = await getAuthMeCached()
    if (data && data.authenticated && data.user && data.user.id) {
      setCurrentUserId(data.user.id)
      return currentUserId
    }
    // Authenticated=false (or auth off) => no identity => unscoped keys.
    setCurrentUserId(null)
    return null
  } catch {
    // Leave the previous value; do not flip to unscoped on a blip.
    resolved = true
    return currentUserId
  }
}

/** Map a logical storage key to its per-user physical key.
 * No identity => the key unchanged (auth off, or before `/me` resolves). */
export function userScopedKey(key: string): string {
  if (!currentUserId) return key
  return `${key}${USER_SUFFIX}${currentUserId}`
}

/** The user id encoded in a scoped key, or null when the key is unscoped. */
export function userIdFromScopedKey(key: string): string | null {
  const at = key.lastIndexOf(USER_SUFFIX)
  if (at < 0) return null
  const id = key.slice(at + USER_SUFFIX.length)
  return id.length > 0 ? id : null
}

/** True when `key` belongs to a user other than the current one. */
export function isForeignScopedKey(key: string): boolean {
  const owner = userIdFromScopedKey(key)
  if (owner === null) return false
  return owner !== currentUserId
}

/** Remove every localStorage entry that belongs to a user other than the
 * current one (or every scoped entry when there is no current user).
 * Only touches keys carrying the `::u:` marker, so unscoped preference keys
 * and the auth cache itself are never destroyed. Returns the number removed. */
export function purgeForeignScopedKeys(): number {
  if (typeof localStorage === 'undefined') return 0
  let removed = 0
  try {
    const doomed: string[] = []
    for (let i = 0; i < localStorage.length; i += 1) {
      const key = localStorage.key(i)
      if (key === null) continue
      if (userIdFromScopedKey(key) === null) continue
      if (isForeignScopedKey(key)) doomed.push(key)
    }
    for (const key of doomed) {
      localStorage.removeItem(key)
      removed += 1
    }
  } catch {
    /* private mode / no storage — nothing to purge */
  }
  return removed
}

/** Test-only: reset the module state between specs. */
export function resetUserScopeForTest(): void {
  currentUserId = null
  resolved = false
}
