import { stripTabParam, type TabQuery } from '../helpers/tabTarget'
import { userScopedKey } from '../helpers/userScope'

const ENABLED_KEY = 'pabrik-tabs-enabled'
// The key is a NAMESPACE, not the payload version: the payload's own `v` is what parseTabList checks
// (1 = one flat list, 2 = the same list with an owner per tab). Keeping the key stable is what lets a
// v1 payload migrate in place instead of being orphaned.
const LIST_PREFIX = 'pabrik-tabs:v1:'

export function listKey(windowId: string): string {
  return userScopedKey(`${LIST_PREFIX}${windowId}`)
}

export function readStorage(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

export function writeStorage(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* quota / private mode / no storage — the strip still works in memory */
  }
}

export function removeStorage(key: string): void {
  try {
    localStorage.removeItem(key)
  } catch {
    /* see writeStorage */
  }
}

export function readEnabled(): boolean {
  const raw = readStorage(ENABLED_KEY)
  // ON by default: the strip is a session's title bar now (it carries the session's name, the width
  // control, the sidebar toggle and the close), so the default-off of the deleted window-wide strip
  // no longer applies. Settings → General → "Browser-style tabs" stays as the escape hatch.
  return raw === null ? true : raw === 'true'
}

export function tabQueryOf(query: Record<string, unknown>): TabQuery {
  return stripTabParam(query)
}

export { ENABLED_KEY }
