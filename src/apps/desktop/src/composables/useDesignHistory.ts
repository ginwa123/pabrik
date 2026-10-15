/**
 * `useDesignHistory` — core composable for design-mode undo/redo.
 *
 * Owns the push/pop API + capture helpers. The Pinia store
 * (`useDesignHistoryStore`) is just the data layer; this composable
 * owns the business logic: capturing pre-state, diffing, applying
 * inverse/forward, and wiring up to `workspacesStore` for the
 * actual API calls.
 *
 * Usage:
 *   const pageId = computed(() => activePageId.value)
 *   const history = useDesignHistory(pageId)
 *
 *   history.capturePreState(['elem_A', 'elem_B'])
 *   // ... user drags both elements ...
 *   await history.capturePostState(['elem_A', 'elem_B'])
 *
 *   // Cmd+Z triggers:
 *   await history.undo()
 *
 * The composable reads/writes to the active workspace + item via
 * `workspacesStore.activeWorkspace / activeWorkspaceItemId` at call
 * time — no need to plumb ids through props (matches the pattern in
 * `useDesignHandlers.updateElement`).
 */
import { computed, type ComputedRef } from 'vue'
import { useDesignHistoryStore, type HistoryEntry } from '../stores/designHistory'
import { useWorkspacesStore } from '../stores/workspaces'
import type { DesignElement } from '../api'

export interface UseDesignHistory {
  canUndo: ComputedRef<boolean>
  canRedo: ComputedRef<boolean>
  nextUndoLabel: ComputedRef<string | null>
  nextRedoLabel: ComputedRef<string | null>
  undo(): Promise<void>
  redo(): Promise<void>
  capturePreState(ids: string[]): void
  capturePostState(ids: string[]): Promise<void>
  captureDelete(elements: Array<{ element: DesignElement; htmlBody: string | null }>): Promise<void>
  captureCreate(element: DesignElement, htmlBody: string | null): Promise<void>
  captureReorder(beforeOrder: string[], afterOrder: string[]): Promise<void>
  captureGroup(parentId: string, childIds: string[], beforeParentExisted: boolean): Promise<void>
}

let nextEntryId = 1
function generateEntryId(): string {
  // Monotonic integer-based id; we don't need ULIDs here because the in-memory store doesn't
  // deduplicate. Stable across localStorage round-trips would need a ULID; v1 doesn't promise
  // cross-session dedup.
  return `entry_${Date.now()}_${nextEntryId++}`
}

function diffElement(before: DesignElement, after: DesignElement): Partial<DesignElement> {
  const changed: Partial<DesignElement> = {}
  // Compare every column we know about. Skip non-payload fields like
  // `created_at` / `updated_at` (those change on every UPDATE).
  const tracked: Array<keyof DesignElement> = [
    'name',
    'type',
    'x',
    'y',
    'width',
    'height',
    'rotation',
    'fill',
    'stroke',
    'stroke_width',
    'corner_radius',
    'opacity',
    'text_content',
    'text_style',
    'image_url',
    'parent_id',
    'z_index',
    'position',
  ]
  for (const key of tracked) {
    if (before[key] !== after[key]) {
      // Type assertion: we're writing a known field of DesignElement
      // by name. Safe because `tracked` is a literal list.
      ;(changed as Record<string, unknown>)[key as string] = after[key]
    }
  }
  return changed
}

export function useDesignHistory(pageId: ComputedRef<string>): UseDesignHistory {
  const historyStore = useDesignHistoryStore()
  const workspacesStore = useWorkspacesStore()

  // Pre-state is captured synchronously at gesture start (pointerdown,
  // keydown, dialog open). It's held in a closure ref so the
  // matching capturePostState can diff against it.
  let preState: Map<string, DesignElement> = new Map()

  function findElement(id: string): DesignElement | null {
    const itemId = workspacesStore.activeWorkspaceItemId
    const ws = workspacesStore.activeWorkspace
    if (!itemId || !ws) return null
    const item = workspacesStore.workspaces
      .find((w) => w.id === ws.id)
      ?.items.find((i) => i.id === itemId)
    if (!item?.design_elements) return null
    return (item.design_elements.find((e) => e.id === id) ?? null) as DesignElement | null
  }

  function pushEntry(entry: HistoryEntry): void {
    historyStore.push(pageId.value, entry)
    scheduleSave()
  }

  // Debounced localStorage save. The 500ms window batches bursts
  // of pushes (e.g. arrow-key nudge) into one write.
  let saveTimer: ReturnType<typeof setTimeout> | null = null
  function scheduleSave(): void {
    if (saveTimer) clearTimeout(saveTimer)
    saveTimer = setTimeout(() => {
      saveTimer = null
      const ws = workspacesStore.activeWorkspace
      const itemId = workspacesStore.activeWorkspaceItemId
      if (!ws || !itemId) return
      historyStore.saveToStorage(
        ws.id,
        itemId,
        pageId.value,
        historyStore.getStack(pageId.value),
      )
    }, 500)
  }

  function capturePreState(ids: string[]): void {
    preState = new Map()
    for (const id of ids) {
      const el = findElement(id)
      if (el) preState.set(id, { ...el })
    }
  }

  async function capturePostState(ids: string[]): Promise<void> {
    if (preState.size === 0) return
    const changes: HistoryEntry['changes'] = []
    for (const id of ids) {
      const before = preState.get(id)
      const after = findElement(id)
      if (!before || !after) continue
      const diff = diffElement(before, after)
      if (Object.keys(diff).length > 0) {
        changes.push({
          elementId: id,
          before: diffElement(after, before), // pre-shape for inverse
          after: diff,
        })
      }
    }
    preState = new Map()
    if (changes.length === 0) return
    pushEntry({
      id: generateEntryId(),
      timestamp: Date.now(),
      label: changes.length === 1 ? 'Move element' : `Move ${changes.length} elements`,
      pageId: pageId.value,
      kind: 'update',
      changes,
    })
  }

  async function captureDelete(
    elements: Array<{ element: DesignElement; htmlBody: string | null }>,
  ): Promise<void> {
    if (elements.length === 0) return
    // Chunk 6 (undo/redo plan): if the caller didn't provide an HTML body, fetch it from the
    // backend BEFORE the delete happens. The captured body is what `applyInverse` will PATCH back
    // on undo.

    // Without this, undo restores the SQL row but the on-disk HTML file is gone (deleteElement
    // deletes it best-effort).
    const enriched = await Promise.all(
      elements.map(async (e) => {
        if (e.htmlBody !== null) return e
        if (!e.element.file_path) return e
        try {
          const resp = await import('../api').then((m) =>
            m.getDesignElementHtml(
              workspacesStore.activeWorkspace?.id ?? '',
              workspacesStore.activeWorkspaceItemId ?? '',
              pageId.value,
              e.element.id,
            ),
          )
          return { element: e.element, htmlBody: resp.html }
        } catch {
          return e
        }
      }),
    )
    pushEntry({
      id: generateEntryId(),
      timestamp: Date.now(),
      label:
        enriched.length === 1
          ? `Delete ${enriched[0]!.element.name}`
          : `Delete ${enriched.length} elements`,
      pageId: pageId.value,
      kind: 'delete',
      deletedElements: enriched.map((e) => ({
        element: { ...e.element },
        htmlBody: e.htmlBody,
      })),
    })
  }

  async function captureCreate(
    element: DesignElement,
    htmlBody: string | null,
  ): Promise<void> {
    pushEntry({
      id: generateEntryId(),
      timestamp: Date.now(),
      label: `Create ${element.name}`,
      pageId: pageId.value,
      kind: 'create',
      newElementId: element.id,
      deletedElements: [
        {
          element: { ...element },
          htmlBody,
        },
      ],
    })
  }

  async function captureReorder(
    beforeOrder: string[],
    afterOrder: string[],
  ): Promise<void> {
    pushEntry({
      id: generateEntryId(),
      timestamp: Date.now(),
      label: 'Reorder elements',
      pageId: pageId.value,
      kind: 'reorder',
      reorderOp: { beforeOrder, afterOrder },
    })
  }

  async function captureGroup(
    parentId: string,
    childIds: string[],
    beforeParentExisted: boolean,
  ): Promise<void> {
    pushEntry({
      id: generateEntryId(),
      timestamp: Date.now(),
      label: childIds.length === 1 ? 'Group 1 element' : `Group ${childIds.length} elements`,
      pageId: pageId.value,
      kind: 'group',
      groupOp: { parentId, childIds, beforeParentExisted },
    })
  }

  async function undo(): Promise<void> {
    const entry = historyStore.popPast(pageId.value)
    if (!entry) return
    historyStore.getStack(pageId.value).future.push(entry)
    await applyInverse(entry)
    scheduleSave()
  }

  async function redo(): Promise<void> {
    const entry = historyStore.popFuture(pageId.value)
    if (!entry) return
    historyStore.getStack(pageId.value).past.push(entry)
    await applyForward(entry)
    scheduleSave()
  }

  async function applyInverse(entry: HistoryEntry): Promise<void> {
    switch (entry.kind) {
      case 'update':
        if (entry.changes) {
          for (const change of entry.changes) {
            const el = findElement(change.elementId)
            if (!el) continue
            await workspacesStore.updateDesignElement(
              workspacesStore.activeWorkspace?.id ?? '',
              workspacesStore.activeWorkspaceItemId ?? '',
              pageId.value,
              change.elementId,
              change.before as Partial<DesignElement>,
            )
          }
        }
        break
      case 'delete':
      case 'create':
        if (entry.deletedElements) {
          for (const d of entry.deletedElements) {
            await workspacesStore.addDesignElement(
              workspacesStore.activeWorkspace?.id ?? '',
              workspacesStore.activeWorkspaceItemId ?? '',
              pageId.value,
              {
                name: (d.element as DesignElement).name,
                type: (d.element as DesignElement).type,
                html: d.htmlBody ?? '',
                x: (d.element as DesignElement).x,
                y: (d.element as DesignElement).y,
                width: (d.element as DesignElement).width,
                height: (d.element as DesignElement).height,
                fill: (d.element as DesignElement).fill,
                rotation: (d.element as DesignElement).rotation,
                corner_radius: (d.element as DesignElement).corner_radius,
                opacity: (d.element as DesignElement).opacity,
                text_content: (d.element as DesignElement).text_content,
                text_style: (d.element as DesignElement).text_style,
                image_url: (d.element as DesignElement).image_url,
              },
            )
          }
        }
        break
      case 'reorder':
        if (entry.reorderOp) {
          // Inverse of a reorder is... another reorder with the before/after swapped. We don't
          // currently have an "absolute set order" API; the closest is reorderDesignElements with
          // `bring_forward` / `send_backward`.

          // Full inverse is out of scope for v1 (the keyboard path's inverse is "back to the
          // original z-index values", which would need either a snapshot diff or a new endpoint).
          // For now we no-op.
        }
        break
      case 'group':
        // Inverse of group = ungroup. No endpoint exists yet
        // (see Chunk 9 deferred list). No-op for v1.
        break
      case 'html_edit':
        if (entry.changes && entry.changes[0]) {
          const change = entry.changes[0]
          await workspacesStore.updateDesignElementHtml(
            workspacesStore.activeWorkspace?.id ?? '',
            workspacesStore.activeWorkspaceItemId ?? '',
            pageId.value,
            change.elementId,
            change.htmlBody?.before ?? '',
          )
        }
        break
    }
  }

  async function applyForward(entry: HistoryEntry): Promise<void> {
    switch (entry.kind) {
      case 'update':
        if (entry.changes) {
          for (const change of entry.changes) {
            await workspacesStore.updateDesignElement(
              workspacesStore.activeWorkspace?.id ?? '',
              workspacesStore.activeWorkspaceItemId ?? '',
              pageId.value,
              change.elementId,
              change.after as Partial<DesignElement>,
            )
          }
        }
        break
      case 'delete':
      case 'create':
        if (entry.deletedElements) {
          for (const d of entry.deletedElements) {
            await workspacesStore.deleteDesignElement(
              workspacesStore.activeWorkspace?.id ?? '',
              workspacesStore.activeWorkspaceItemId ?? '',
              pageId.value,
              (d.element as DesignElement).id,
            )
          }
        }
        break
      case 'reorder':
        if (entry.reorderOp) {
          // Forward is also a no-op for v1 (see applyInverse).
        }
        break
      case 'group':
        // Forward group is also a no-op for v1.
        break
      case 'html_edit':
        if (entry.changes && entry.changes[0]) {
          const change = entry.changes[0]
          await workspacesStore.updateDesignElementHtml(
            workspacesStore.activeWorkspace?.id ?? '',
            workspacesStore.activeWorkspaceItemId ?? '',
            pageId.value,
            change.elementId,
            change.htmlBody?.after ?? '',
          )
        }
        break
    }
  }

  return {
    canUndo: computed(() => historyStore.getStack(pageId.value).past.length > 0),
    canRedo: computed(() => historyStore.getStack(pageId.value).future.length > 0),
    nextUndoLabel: computed(() => {
      const s = historyStore.getStack(pageId.value)
      return s.past.length > 0 ? s.past[s.past.length - 1]!.label : null
    }),
    nextRedoLabel: computed(() => {
      const s = historyStore.getStack(pageId.value)
      return s.future.length > 0 ? s.future[s.future.length - 1]!.label : null
    }),
    undo,
    redo,
    capturePreState,
    capturePostState,
    captureDelete,
    captureCreate,
    captureReorder,
    captureGroup,
  }
}

export type { HistoryEntry }
