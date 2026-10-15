/**
 * Per-window identity for the tab list.
 *
 * `sessionStorage` is exactly the right lifetime here: it is per browser
 * tab / webview window, and it survives a reload of that window while a
 * brand-new window starts empty — which is what a browser does with its
 * tab strip. That is also why the tab list itself is keyed by this id in
 * `localStorage` instead of living in `sessionStorage`.
 *
 * Known limitation: some engines copy `sessionStorage` when a tab is
 * duplicated; such a duplicate shares the tab list with its source. That
 * is a benign outcome, not a corruption, so it is not defended against.
 */
const STORAGE_KEY = 'pabrik-window-id'

let cached: string | null = null

export function newWindowId(): string {
  return `w_${Math.random().toString(36).slice(2, 12)}`
}

/** Read-or-create the window id. Never throws: a host without
 * `sessionStorage` (or one that denies it, e.g. a hardened webview)
 * still gets a stable id for the lifetime of the page. */
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
