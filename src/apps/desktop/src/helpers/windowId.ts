/** Per-window identity for the tab list. */
const STORAGE_KEY = 'pabrik-window-id'

let cached: string | null = null

export function newWindowId(): string {
  return `w_${Math.random().toString(36).slice(2, 12)}`
}

/** Read-or-create the window id. */
export function getWindowId(): string {
  if (cached) return cached
  const created = newWindowId()
  try {
    const storage = (globalThis as { sessionStorage?: Storage }).sessionStorage
    if (!storage) {
      cached = created
      return created
    }
    const existing = storage.getItem(STORAGE_KEY)
    if (existing) {
      cached = existing
      return existing
    }
    storage.setItem(STORAGE_KEY, created)
    cached = created
    return created
  } catch {
    cached = created
    return created
  }
}

/** Test seam: forget the module-level cache so a test can re-read storage. */
export function __resetWindowIdForTests(): void {
  cached = null
}
