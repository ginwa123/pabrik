import { stripTabParam, type TabQuery } from '../helpers/tabTarget'
import { userScopedKey } from '../helpers/userScope'

const ENABLED_KEY = 'pabrik-tabs-enabled'
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
  // Tab mode defaults to OFF — users found the strip confusing.
  // Opt-in via Settings → General → "Browser-style tabs".
  return raw === null ? false : raw === 'true'
}

export function tabQueryOf(query: Record<string, unknown>): TabQuery {
  return stripTabParam(query)
}

export { ENABLED_KEY }
