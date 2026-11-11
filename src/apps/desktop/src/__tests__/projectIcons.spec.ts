/** Behaviour of the per-project icon: which glyph a row draws, and what the
 * row looks like after the server accepts or rejects the write. The icon lives
 * on `workspace_items.icon` (Migration 147). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { isUiIconName, projectIconFor, PROJECT_ICON_NAMES } from '../stores/projectIcons'
import { ICON_PATHS } from '../components/ui/icons'

const WORKSPACE_ID = 'ws_1'
const ITEM_ID = 'item_1'

function seedWorkspace(icon: string | null = null) {
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: WORKSPACE_ID,
      name: 'Workspace',
      icon: 'folder',
      expanded: true,
      items: [{ id: ITEM_ID, name: 'Board', item_type: 'kanban', icon }],
    },
  ] as never
  return store
}

describe('projectIconFor', () => {
  it('draws a closed folder for a project with no override', () => {
    expect(projectIconFor({ icon: null }, false)).toBe('folder')
  })

  it('draws an open folder for an expanded project with no override', () => {
    expect(projectIconFor({ icon: null }, true)).toBe('folder-open')
  })

  it('draws the override whether the row is expanded or not', () => {
    expect(projectIconFor({ icon: 'tree' }, false)).toBe('tree')
    expect(projectIconFor({ icon: 'tree' }, true)).toBe('tree')
  })

  it('falls back to the folder pair when the stored name is not one this build can draw', () => {
    // A row written by a build that had an icon this one dropped. Rendering
    // nothing would leave a blank row, so the fallback is the behaviour.
    expect(projectIconFor({ icon: 'icon-from-a-future-build' }, false)).toBe('folder')
    expect(projectIconFor({ icon: 'icon-from-a-future-build' }, true)).toBe('folder-open')
  })

  it('treats a missing item as a closed folder rather than throwing', () => {
    expect(projectIconFor(undefined, false)).toBe('folder')
    expect(projectIconFor(null, true)).toBe('folder-open')
  })
})

describe('isUiIconName', () => {
  it('accepts every name the registry can draw', () => {
    for (const name of Object.keys(ICON_PATHS)) {
      expect(isUiIconName(name)).toBe(true)
    }
  })

  it('rejects a prototype key, which would otherwise render an empty glyph', () => {
    // `'constructor' in ICON_PATHS` is true, so an `in`-based guard would let
    // this through and `ICON_PATHS['constructor']` would draw nothing.
    expect(isUiIconName('constructor')).toBe(false)
    expect(isUiIconName('toString')).toBe(false)
  })

  it('rejects a non-string', () => {
    expect(isUiIconName(null)).toBe(false)
    expect(isUiIconName(42)).toBe(false)
  })
})

describe('PROJECT_ICON_NAMES', () => {
  it('is sorted, so the picker grid does not reshuffle between builds', () => {
    const sorted = [...PROJECT_ICON_NAMES].sort()
    expect(PROJECT_ICON_NAMES).toEqual(sorted)
  })
})

describe('workspacesStore.setItemIcon', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('repaints the row with the picked glyph', async () => {
    const store = seedWorkspace(null)
    vi.spyOn(api, 'updateWorkspaceItem').mockResolvedValue({} as never)

    await store.setItemIcon(WORKSPACE_ID, ITEM_ID, 'tree')

    expect(store.workspaces[0]!.items[0]!.icon).toBe('tree')
  })

  it('clears the override when the user resets to default', async () => {
    const store = seedWorkspace('tree')
    vi.spyOn(api, 'updateWorkspaceItem').mockResolvedValue({} as never)

    await store.setItemIcon(WORKSPACE_ID, ITEM_ID, null)

    expect(store.workspaces[0]!.items[0]!.icon).toBeNull()
  })

  it('restores the previous glyph when the server rejects the write', async () => {
    const store = seedWorkspace('box')
    vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.spyOn(api, 'updateWorkspaceItem').mockRejectedValue(new Error('offline'))

    await expect(store.setItemIcon(WORKSPACE_ID, ITEM_ID, 'tree')).rejects.toThrow('offline')

    // The row must not keep a glyph the database never stored.
    expect(store.workspaces[0]!.items[0]!.icon).toBe('box')
  })
})
