/** Per-user browser-storage namespacing (plan 2026-09-25, W5). */
import { getAuthMeCached } from './authMe'

/** Separator between the logical key and the user id. */
const USER_SUFFIX = '::u:'

/**  * The identity currently in effect. `null` means "no identity" — auth off, or `/api/auth/me` has
 * not resolved yet — and `userScopedKey` then returns the key unchanged. */
let currentUserId: string | null = null

/** True once `refreshCurrentUserId` has completed at least once. */
let resolved = false

/**  * Synchronously set the identity. Called by the auth flow on login, logout, and whenever
 * `/api/auth/me` reports a different id. Passing `null` (or an empty string) means "no identity"
 * and disables scoping. */
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

/** Resolve the identity from the cached `/api/auth/me` and store it. Returns the id (or null). */
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

/** Remove every localStorage entry that belongs to a user other than the current one (or every
 * scoped entry when there is no current user). Only touches keys carrying the `::u:` marker, so
 * unscoped preference keys and the auth cache itself are never destroyed. */
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
