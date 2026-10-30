import { userScopedKey } from '../../helpers/userScope'

const STORAGE_KEY_WORKSPACE_EXPANDED = 'pabrik-workspace-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_EXPANDED = 'pabrik-workspace-item-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED = 'pabrik-workspace-item-tasks-expanded'
// Persisted header-dropdown selection.
const STORAGE_KEY_ACTIVE_WORKSPACE = 'pabrik-active-workspace'

// Load expanded workspace IDs from localStorage
export function loadExpandedWorkspaces(): Set<string> {
  const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_EXPANDED)
  if (saved) {
    try {
      const parsed = JSON.parse(saved)
      if (Array.isArray(parsed)) {
        return new Set(parsed)
      }
    } catch (e) {
      console.error('Failed to parse expanded workspaces:', e)
    }
  }
  return new Set()
}

// Load expanded workspace item IDs from localStorage (for nested folder expansion)
export function loadExpandedItems(): Set<string> {
  const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_EXPANDED)
  if (saved) {
    try {
      const parsed = JSON.parse(saved)
      if (Array.isArray(parsed)) {
        return new Set(parsed)
      }
    } catch (e) {
      console.error('Failed to parse expanded items:', e)
    }
  }
  return new Set()
}

// Load expanded workspace item IDs for tasks list from localStorage
export function loadExpandedItemIds(): Record<string, boolean> {
  const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED)
  if (saved) {
    try {
      const parsed = JSON.parse(saved)
      if (Array.isArray(parsed)) {
        const record: Record<string, boolean> = {}
        for (const id of parsed) {
          record[id] = true
        }
        return record
      }
    } catch (e) {
      console.error('Failed to parse expanded item IDs:', e)
    }
  }
  return {}
}

// Save expanded workspace IDs to localStorage
export function saveExpandedWorkspaces(expandedIds: Set<string>) {
  localStorage.setItem(STORAGE_KEY_WORKSPACE_EXPANDED, JSON.stringify(Array.from(expandedIds)))
}

// Save expanded workspace item IDs to localStorage (for nested folder expansion)
export function saveExpandedItems(expandedIds: Set<string>) {
  localStorage.setItem(STORAGE_KEY_WORKSPACE_ITEM_EXPANDED, JSON.stringify(Array.from(expandedIds)))
}

// Save expanded workspace item IDs for tasks list to localStorage
export function saveExpandedItemIds(expandedIds: Record<string, boolean>) {
  localStorage.setItem(
    STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED,
    JSON.stringify(Object.keys(expandedIds)),
  )
}

// jsdom 29 dropped localStorage from the default globals — specs
// that don't install the stub must not crash the getter.
export function readActiveWorkspaceKey(): string | null {
  try {
    return localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE))
  } catch {
    return null
  }
}

export function writeActiveWorkspaceKey(value: string | null) {
  try {
    if (value === null) {
      localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE))
    } else {
      localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE), value)
    }
  } catch {
    // Storage unavailable — the selection just isn't persisted.
  }
}
