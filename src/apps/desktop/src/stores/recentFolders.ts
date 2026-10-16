/** `useRecentFoldersStore` — Pinia store backing the FilePickerDialog's Recent tab. */
import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY = 'pabrik-folder-picker-recent:v1'
const CAP = 12
const WRITE_DEBOUNCE_MS = 200

export interface RecentFolderEntry {
  path: string
  lastUsedAt: number // Unix-ms
  pinned: boolean
}

function loadFromStorage(): RecentFolderEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    // Defensive: validate each entry.
    return parsed
      .filter(
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        (e: any) =>
          e &&
          typeof e.path === 'string' &&
          typeof e.lastUsedAt === 'number' &&
          (e.pinned === true || e.pinned === false),
      )
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      .map((e: any) => ({
        path: e.path,
        lastUsedAt: e.lastUsedAt,
        pinned: e.pinned,
      }))
  } catch {
    // Corrupt JSON or private mode — start empty.
    return []
  }
}

function saveToStorage(entries: RecentFolderEntry[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entries))
  } catch {
    // localStorage quota exceeded / private mode — swallow silently.
    // The in-memory state is still updated; the next page load will
    // start fresh from the (persisted) shadow.
  }
}

export const useRecentFoldersStore = defineStore('recentFolders', () => {
  const entries = ref<RecentFolderEntry[]>(loadFromStorage())

  // Sort helper: pinned desc, lastUsedAt desc.
  function sorted(list: RecentFolderEntry[]): RecentFolderEntry[] {
    return [...list].sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
      return b.lastUsedAt - a.lastUsedAt
    })
  }

  let writeTimer: ReturnType<typeof setTimeout> | null = null
  function scheduleWrite(): void {
    if (writeTimer) clearTimeout(writeTimer)
    writeTimer = setTimeout(() => {
      saveToStorage(entries.value)
      writeTimer = null
    }, WRITE_DEBOUNCE_MS)
  }

  function addRecent(path: string): void {
    if (!path) return
    const now = Date.now()
    const existing = entries.value.find((e) => e.path === path)
    if (existing) {
      // Dedupe: bump lastUsedAt, keep pinned.
      existing.lastUsedAt = now
    } else {
      entries.value.push({ path, lastUsedAt: now, pinned: false })
    }
    // Cap: evict the OLDEST non-pinned entry if over the cap. Pinned
    // entries are exempt from auto-eviction.
    if (entries.value.length > CAP) {
      const candidates = entries.value
        .filter((e) => !e.pinned)
        .sort((a, b) => a.lastUsedAt - b.lastUsedAt)
      while (entries.value.length > CAP && candidates.length > 0) {
        const victim = candidates.shift()!
        entries.value = entries.value.filter((e) => e.path !== victim.path)
      }
    }
    scheduleWrite()
  }

  function togglePin(path: string): void {
    const entry = entries.value.find((e) => e.path === path)
    if (!entry) return
    entry.pinned = !entry.pinned
    scheduleWrite()
  }

  function removeRecent(path: string): void {
    entries.value = entries.value.filter((e) => e.path !== path)
    scheduleWrite()
  }

  function list(): RecentFolderEntry[] {
    return sorted(entries.value)
  }

  return {
    entries,
    addRecent,
    togglePin,
    removeRecent,
    list,
  }
})
