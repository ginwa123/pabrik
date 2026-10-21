import { useNotificationStore } from '../stores/notifications'
import { useWorkspacesStore } from '../stores/workspaces'
import { designLogger } from '../helpers/designLogger'
import type { DesignElement, DesignElementType } from '../api'

/** AppLayout's design-mode handlers, extracted into a composable so they're directly testable (SFC
 * <script setup> functions aren't importable as named exports). The composable owns NO state — it
 * reads the active workspace/item/page from the store and dispatches to the store actions. */
export interface UseDesignHandlersArgs {
  workspaceId: string | { value: string } | (() => string)
  itemId: string | { value: string } | (() => string)
  pageId: string | { value: string } | (() => string)
  /**    * Reactive Set of currently-selected element ids. The composable reads `selectedIds.value.size`
   * to enforce the 2+ rule and replaces `selectedIds.value = new Set()` after a successful group.
   * Pass it as a ref/computed so changes from DesignView propagate here. */
  selectedIds: { value: Set<string> }
  /**    * Optional override for the browser prompt. The default uses `window.prompt` (the first-cut
   * implementation; Figma uses an inline rename affordance — see plan §7.1 for the follow-up).
   * Tests pass a stub to avoid blocking on the real prompt. */
  promptForName?: (defaultValue: string) => string | null
}

// Normalize an "id source" arg (string | ref | getter) to a string
// evaluated AT CALL TIME so the value is always fresh even when the
// caller passes a computed/ref. Falls back to '' for empty refs.
function readId(id: string | { value: string } | (() => string)): string {
  if (typeof id === 'string') return id
  if (typeof id === 'function') return id()
  if (id && typeof id === 'object' && 'value' in id) return id.value
  return ''
}

export function useDesignHandlers(args?: UseDesignHandlersArgs) {
  const workspacesStore = useWorkspacesStore()
  const notificationStore = useNotificationStore()

  async function updateElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
    patch: Record<string, unknown>,
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn('[useDesignHandlers.updateElement] no activeDesignPageId; ignoring patch', { workspaceId, itemId, elementId, patch })
      return
    }
    // DEPRECATED path — kept for back-compat. New callers should use
    // `translateElement` (move) or `resizeElement` (resize).
    const keys = Object.keys(patch)
    const isGeometryOnly = keys.length > 0 && keys.every((k) => k === 'x' || k === 'y' || k === 'width' || k === 'height' || k === 'rotation')
    try {
      if (isGeometryOnly) {
        await workspacesStore.updateDesignElementGeometry(
          workspaceId, itemId, pageId, elementId,
          patch as { x?: number; y?: number; width?: number; height?: number; rotation?: number },
        )
      } else {
        await workspacesStore.updateDesignElement(
          workspaceId, itemId, pageId, elementId, patch,
        )
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to update element', message)
    }
  }

  /** NEW (2026-08-06, split-move-resize plan) — translate (move) a single element by a (dx, dy)
   * delta. Routes to POST /translate. */
  async function translateElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
    dx: number,
    dy: number,
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      designLogger.warn({
        reason: 'app:noop:noActivePage',
        caller: 'useDesignHandlers.translateElement',
        dx,
        dy,
        noActivePage: true,
        workspaceId,
        itemId,
        pageId: '',
        extra: { elementId },
      })
      return
    }
    designLogger.info({
      reason: 'app:translateElement',
      caller: 'useDesignHandlers.translateElement',
      dx,
      dy,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    try {
      await workspacesStore.translateDesignElement(workspaceId, itemId, pageId, elementId, dx, dy)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to translate element', message)
    }
  }

  /** NEW (2026-08-06, split-move-resize plan) — resize a single element with absolute
   * x/y/width/height/rotation fields. Routes to POST /resize. */
  async function resizeElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
    patch: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      designLogger.warn({
        reason: 'app:noop:noActivePage',
        caller: 'useDesignHandlers.resizeElement',
        patch,
        noActivePage: true,
        workspaceId,
        itemId,
        pageId: '',
        extra: { elementId },
      })
      return
    }
    designLogger.info({
      reason: 'app:resizeElement',
      caller: 'useDesignHandlers.resizeElement',
      patch,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    try {
      await workspacesStore.resizeDesignElement(workspaceId, itemId, pageId, elementId, patch)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to resize element', message)
    }
  }

  async function deleteElement(workspaceId: string, itemId: string, elementId: string): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn('[useDesignHandlers.deleteElement] no activeDesignPageId; ignoring', { workspaceId, itemId, elementId })
      return
    }
    if (!confirm('Delete this element?')) return
    try {
      await workspacesStore.deleteDesignElement(workspaceId, itemId, pageId, elementId)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to delete element', message)
    }
  }

  /** NEW (regression fix, 2026-08-14, "design mode, add element manual not working"). Routes the
   * `createElement({ name, type, html })` payload from the AddDesignElementDialog to the
   * workspacesStore.addDesignElement action → POST /elements endpoint. */
  async function createElement(
    workspaceId: string,
    itemId: string,
    body: {
      name: string
      type: DesignElementType
      html: string
      [k: string]: unknown
    },
  ): Promise<DesignElement | null> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn('[useDesignHandlers.createElement] no activeDesignPageId; ignoring', {
        workspaceId,
        itemId,
        name: body.name,
        type: body.type,
      })
      return null
    }
    try {
      return await workspacesStore.addDesignElement(
        workspaceId,
        itemId,
        pageId,
        body,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to add element', message)
      return null
    }
  }

  /** NEW (Chunk 6 of grouped-layers plan). Figma convention: Cmd/Ctrl+G wraps the current selection
   * into a new `group` at the union bbox. Selection gate: silent no-op when `selectedIds.size < 2`
   * (matches Figma). */
  async function groupSelection(): Promise<void> {
    if (!args) {
      console.warn('[useDesignHandlers.groupSelection] no args provided; skipping')
      return
    }
    const workspaceId = readId(args.workspaceId)
    const itemId = readId(args.itemId)
    const pageId = readId(args.pageId)
    if (!workspaceId || !itemId || !pageId) {
      // Missing ids — quiet no-op (AppLayout/DesignView could race
      // a keypress before the page is loaded). matches how
      // `updateElement`/`deleteElement` handle the no-page case.
      return
    }
    const { selectedIds, promptForName } = args
    // Figma convention: silent no-op when fewer than 2 elements are
    // selected. Reading .size happens at call time so multi-click
    // scenarios (last selection before keystroke) read the live value.
    if (selectedIds.value.size < 2) return
    // Selected ids is stored as a Set; the API expects an array.
    const childIds = Array.from(selectedIds.value)
    const defaultName = `Group ${childIds.length}`
    // First-cut implementation: window.prompt. A future inline-rename affordance (plan §7.1) would
    // replace this with an input UI bound to the new group's name. Tests pass `promptForName` to
    // bypass the real browser prompt.
    const promptFn = promptForName ?? ((defaultValue: string): string | null => window.prompt('Name the new group:', defaultValue))
    const name = promptFn(defaultName)
    // User clicked Cancel — treat as no-op (don't create an empty group).
    if (name === null) return
    try {
      await workspacesStore.groupDesignElements(workspaceId, itemId, pageId, {
        child_ids: childIds,
        name,
        type: 'group',
      })
      // Clear selection so the user can immediately Cmd+G again on a
      // fresh selection (Figma behavior — grouping collapses to the
      // new parent, then the user picks the next group).
      selectedIds.value = new Set()
      // The notification store only exposes notifyError (a single success-vs-error style is
      // overkill for the 1-shot success case here). Success notifications auto-dismiss in 5s like
      // error notifications, so the UX is consistent.
      notificationStore.notifyError(
        `Grouped ${childIds.length} elements into "${name}".`,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to group selection.')
    }
  }

  /** NEW (Chunk 9 of grouped-layers plan). Figma convention: Cmd/Ctrl+Shift+G dissolves a `group`
   * (or `frame`) — its direct children are reparented to the group's parent (or top-level if the
   * group had no parent), the group row is deleted. */
  async function ungroupSelection(elementId: string): Promise<void> {
    if (!args) {
      console.warn('[useDesignHandlers.ungroupSelection] no args provided; skipping')
      return
    }
    const workspaceId = readId(args.workspaceId)
    const itemId = readId(args.itemId)
    const pageId = readId(args.pageId)
    if (!workspaceId || !itemId || !pageId || !elementId) {
      // Missing ids — quiet no-op.
      return
    }
    try {
      const result = await workspacesStore.ungroupDesignElements(
        workspaceId, itemId, pageId, elementId,
      )
      // Clear selection so the user can immediately Ungroup again on a
      // fresh selection (Figma behavior — Ungroup collapses to the
      // new top-level children, then the user picks the next one).
      args.selectedIds.value = new Set()
      notificationStore.notifyError(
        `Ungrouped ${result.orphaned.length} elements.`,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to ungroup.')
    }
  }

  /** NEW (2026-08-06, design-leave-group plan). Figma-style "Pull out of group" affordance: pull
   * the SINGLE selected element out of its current parent group/frame to top-level. Distinct from
   * `ungroupSelection` (which dissolves the selected group itself). */
  async function moveToPage(
    elementId: string,
    newPageId: string,
  ): Promise<void> {
    if (!args) {
      console.warn('[useDesignHandlers.moveToPage] no args provided; skipping')
      return
    }
    const workspaceId = readId(args.workspaceId)
    const itemId = readId(args.itemId)
    const pageId = readId(args.pageId)
    if (!workspaceId || !itemId || !pageId || !elementId || !newPageId) {
      // Missing ids — quiet no-op (same contract as `leaveGroup`).
      return
    }
    try {
      const updated = await workspacesStore.moveDesignElementToPage(
        workspaceId,
        itemId,
        pageId,
        elementId,
        { new_page_id: newPageId, apply_to_children: true },
      )
      if (!updated) {
        // Store action already showed an error toast.
        return
      }
      // Clear selection — the element has moved to a different page
      // and the canvas on the source page no longer shows it (matches
      // `leaveGroup` UX).
      args.selectedIds.value = new Set()
      notificationStore.notifyError(
        `Moved "${updated[0]?.name ?? elementId}" to the target page.`,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to move element to page.')
    }
  }

  async function leaveGroup(elementId: string): Promise<void> {
    if (!args) {
      console.warn('[useDesignHandlers.leaveGroup] no args provided; skipping')
      return
    }
    const workspaceId = readId(args.workspaceId)
    const itemId = readId(args.itemId)
    const pageId = readId(args.pageId)
    if (!workspaceId || !itemId || !pageId || !elementId) {
      // Missing ids — quiet no-op.
      return
    }
    try {
      await workspacesStore.reparentDesignElementsBatch(
        workspaceId,
        itemId,
        pageId,
        {
          element_ids: [elementId],
          new_parent_id: null,
        },
      )
      // Clear selection so the user can immediately Leave group again on a fresh selection (Figma
      // behavior — the just- pulled-out element stays highlighted through spurious context menus
      // unless we clear).
      args.selectedIds.value = new Set()
      notificationStore.notifyError(
        'Left group. Element moved to top-level.',
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to leave group.')
    }
  }

  /** NEW (Chunk 2 Task 2.3 of drag-to-reparent plan). Figma-style drag-and-drop affordance:
   * reparent 1 OR N selected rows into the same target (a `group`/`frame` row, or top-level). */
  async function reparentLayers(payload: {
    workspaceId: string
    itemId: string
    pageId: string
    elementIds: string[]
    newParentId: string | null
  }): Promise<void> {
    const { workspaceId, itemId, pageId, elementIds, newParentId } = payload
    if (!workspaceId || !itemId || !pageId) return
    if (elementIds.length === 0) return
    try {
      await workspacesStore.reparentDesignElementsBatch(
        workspaceId,
        itemId,
        pageId,
        {
          element_ids: elementIds,
          new_parent_id: newParentId,
        },
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to reparent layers.')
    }
  }

  /** NEW. Figma-style
   * drag affordance: translate 1 OR N elements by a single (dx, dy) delta — the backend cascades
   * the delta to every transitive descendant of each item's element via a recursive CTE. */
  async function moveElementWithDescendants(payload: {
    workspaceId: string
    itemId: string
    pageId: string
    items: Array<{
      element_id: string
      dx: number
      dy: number
      width?: number
      height?: number
      rotation?: number
    }>
  }): Promise<void> {
    const { workspaceId, itemId, pageId, items } = payload
    if (!workspaceId || !itemId || !pageId) return
    if (items.length === 0) return
    designLogger.info({
      reason: 'app:moveWithDescendants',
      caller: 'useDesignHandlers.moveElementWithDescendants',
      ids: items.map((i) => i.element_id),
      workspaceId,
      itemId,
      pageId,
      extra: {
        itemCount: items.length,
        sample: items[0] ? { id: items[0].element_id, dx: items[0].dx, dy: items[0].dy } : null,
      },
    })
    try {
      await workspacesStore.moveDesignElementsBatch(workspaceId, itemId, pageId, items)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to move element.')
    }
  }

  return {
    updateElement,
    translateElement,
    resizeElement,
    deleteElement,
    createElement,
    groupSelection,
    ungroupSelection,
    leaveGroup,
    reparentLayers,
    moveElementWithDescendants,
    moveToPage,
  }
}
