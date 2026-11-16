/** useTaskActions — shared logic for the per-task row / card components. */
import { computed, inject, ref, type Ref } from 'vue'
import type { Task } from '../stores/workspaces'

/** Common props every per-task component accepts. */
export interface TaskComponentProps {
  task: Task
  workspaceId: string
  itemId: string
  /** Where to render the 2px yellow drop indicator on this row/card. */
  dropIndicator?: 'above' | 'below' | null
  /** Absolute path used as the root for `@`-trigger file pickers in descendant editors / markdown renderers. */
  cwd?: string
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
export type EmitFn = (event: any, ...args: any[]) => void

/** Surface returned by the composable. */
export interface UseTaskActionsReturn {
  // Reactive state read by the template.
  dropIndicatorBoxShadow: Ref<string>

  // Event handlers — call from `@click` etc. The handler stops the event's propagation so a click on a nested action button does not also fire `selectTask` on the …
  handleSelectTask: () => void
  handleDeleteTask: (event: Event) => void
  handleRenameTask: (event: Event) => void
  handlePinToggle: (event: Event) => void
}

export function useTaskActions(
  props: TaskComponentProps,
  emit: EmitFn,
): UseTaskActionsReturn {
  // Re-inject processingState from App.vue (same key WorkspaceItem and ChatsList consume).
  const processingState = inject<Ref<Record<string, boolean>>>(
    'processingState',
    ref<Record<string, boolean>>({}),
  )
  void processingState

  // Compute the box-shadow for the row/card's drop indicator.
  const dropIndicatorBoxShadow = computed<string>(() => {
    if (props.dropIndicator === 'above') return 'inset 0 2px 0 0 #facc15' // yellow-400
    if (props.dropIndicator === 'below') return 'inset 0 -2px 0 0 #facc15'
    return 'none'
  })

  const handleSelectTask = () => {
    emit('selectTask', props.task.id)
  }

  const handleDeleteTask = (event: Event) => {
    // Stop the click from bubbling up to the parent <button> (which would call selectTask on the same task).
    event.stopPropagation()
    emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
  }

  const handleRenameTask = (event: Event) => {
    // Stop the click from bubbling up to the parent <button>.
    event.stopPropagation()
    emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
  }

  const handlePinToggle = (event: Event) => {
    // Stop the click from bubbling up to the parent <button> (which would call selectTask on the same task).
    event.stopPropagation()
    // Flip the local optimistic state — the store action will echo the same flip, so the parent's `task.is_pinned` will be updated to match.
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