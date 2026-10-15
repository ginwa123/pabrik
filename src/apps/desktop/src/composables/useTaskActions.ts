/**
 * useTaskActions — shared logic for the per-task row / card components.
 *
 * Extracted from <WorkspaceItemTask> on 2026-07-02 when the single-file
 * variant prop was split into two thin presentation components
 * (WorkspaceItemTaskRow.vue for the sidebar list, WorkspaceItemTaskCard
 * .vue for the kanban card). The components now share this composable
 * for:
 *
 *   - The event handlers (select / delete / rename / pin). The
 *     handlers emit the same payload shape the parent
 *     (<WorkspaceItem> and <KanbanCard>) re-emits verbatim — see
 *     docs/plans/2026-07-01-change-task-to-card-kanban.md.
 *     delete / rename / pin take a DOM event only so they can
 *     `stopPropagation()` it away from the row's @click; hosts whose
 *     actions moved into a Teleported context menu (the kanban card,
 *     and the sidebar row since its hover buttons were migrated) emit
 *     the same payloads directly instead and skip these.
 *   - The drop-indicator box-shadow so pinned-region drag visuals work
 *     in both views.
 *  (Per-task routine affordances were deleted in Migration 084 —
 *  routines are now first-class workspace items.)
 *
 * The composable does NOT own:
 *   - Layout / template — that's the caller's job (row vs card).
 *   - Active-task styling (color/backgroundColor) — the parent
 *     component reads workspacesStore.activeTaskId directly via
 *     :style on its root button.
 *   - Card-only computeds (description, meta row, type-accent) — those
 *     are private to WorkspaceItemTaskCard.vue.
 */
import { computed, inject, ref, type Ref } from 'vue'
import type { Task } from '../stores/workspaces'

/** Common props every per-task component accepts. */
export interface TaskComponentProps {
  task: Task
  workspaceId: string
  itemId: string
  /** Where to render the 2px yellow drop indicator on this row/card. */
  /** Set by the parent <WorkspaceItem> while the user is dragging another pinned row over this one
   * — 'above' draws the line on the top edge (insert-before), 'below' on the bottom edge
   * (insert-after), null means no indicator. */
  dropIndicator?: 'above' | 'below' | null
  /** Absolute path used as the root for `@`-trigger file pickers in descendant editors / markdown
   * renderers. Optional — task-list callers in <WorkspaceItem> don't pass it (no kanban context). */
  /** The kanban column passes it through so `@/path` references in the card's description resolve
   * against the kanban's filesystem path. */
  cwd?: string
}

/**
 * Loose emit signature — accepts any `defineEmits` return value.
 *
 * Vue's `defineEmits` returns a UNION of function overloads (one per
 * event name) whose first parameter is a literal string, e.g.
 * `((evt: "deleteTask", ws: string, item: string, id: string) => void)
 *  & ((evt: "renameTask", ws: string, item: string, id: string, name: string) => void)
 *  & ...`. Passing that union to a function expecting a single
 * signature `(event: string, ...args: any[]) => void` triggers a
 * TS2345 ("string is not assignable to 'deleteTask'") error because
 * the overload's first parameter is narrower than `string`.
 *
 * Using `any` on both the event name AND the args keeps the composable
 * callable from any defineEmits-style emit without casts at the call
 * site. The handlers inside the composable still pass typed args to
 * `emit(...)`, so the contract is preserved end-to-end.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
export type EmitFn = (event: any, ...args: any[]) => void

/** Surface returned by the composable. */
export interface UseTaskActionsReturn {
  // Reactive state read by the template.
  dropIndicatorBoxShadow: Ref<string>

  // Event handlers — call from `@click` etc. The handler stops the
  // event's propagation so a click on a nested action button does not
  // also fire `selectTask` on the root row.
  handleSelectTask: () => void
  handleDeleteTask: (event: Event) => void
  handleRenameTask: (event: Event) => void
  handlePinToggle: (event: Event) => void
}

export function useTaskActions(
  props: TaskComponentProps,
  emit: EmitFn,
): UseTaskActionsReturn {
  // Re-inject processingState from App.vue (same key WorkspaceItem and ChatsList consume). Keyed by
  // task.id == session_id. Reading it here — even though the row/card templates also re-inject it
  // directly — establishes the contract and matches the pre-split WorkspaceItemTask.vue behavior.

  // The `void` keeps linters from flagging the unused binding.
  const processingState = inject<Ref<Record<string, boolean>>>(
    'processingState',
    ref<Record<string, boolean>>({}),
  )
  void processingState

  // Compute the box-shadow for the row/card's drop indicator. Uses box-shadow (not border) so the
  // visual cue doesn't shift the row's height between drag/no-drag states. 'above' -> 2px line on
  // the top edge, 'below' -> 2px line on the bottom edge, null -> none.
  const dropIndicatorBoxShadow = computed<string>(() => {
    if (props.dropIndicator === 'above') return 'inset 0 2px 0 0 #facc15' // yellow-400
    if (props.dropIndicator === 'below') return 'inset 0 -2px 0 0 #facc15'
    return 'none'
  })

  const handleSelectTask = () => {
    emit('selectTask', props.task.id)
  }

  const handleDeleteTask = (event: Event) => {
    // Stop the click from bubbling up to the parent <button> (which
    // would call selectTask on the same task). Same rationale as the
    // rename handler below.
    event.stopPropagation()
    emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
  }

  const handleRenameTask = (event: Event) => {
    // Stop the click from bubbling up to the parent <button>. See
    // handleDeleteTask for the full rationale.
    event.stopPropagation()
    emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
  }

  const handlePinToggle = (event: Event) => {
    // Stop the click from bubbling up to the parent <button> (which
    // would call selectTask on the same task). Same rationale as the
    // other action handlers above.
    event.stopPropagation()
    // Flip the local optimistic state — the store action will echo the same flip, so the parent's
    // `task.is_pinned` will be updated to match. If the API call fails, the store rolls back and
    // our local state is overwritten on the next render.
    emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
  }

  return {
    dropIndicatorBoxShadow,
    handleSelectTask,
    handleDeleteTask,
    handleRenameTask,
    handlePinToggle,
  }
}