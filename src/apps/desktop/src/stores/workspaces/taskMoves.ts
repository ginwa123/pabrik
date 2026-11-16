import type { Ref } from 'vue'
import * as api from '../../api'
import { RECENT_MUTATION_TTL_MS, registerRecentLocalMutations } from './mutationDedupe'
import type { Task, Workspace, WorkspaceItem } from './types'

interface TaskMovesParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
  cacheTaskMutation: (
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ) => Promise<void>
}

export function createTaskMoves(p: TaskMovesParams) {
  const { findItem, cacheTaskMutation } = p

  // Reposition a task within `item.tasks` so it renders at `position` among its column's cards.
  function placeTaskAtColumnPosition(
    item: WorkspaceItem,
    taskId: string,
    columnId: string,
    position: number,
  ): void {
    if (!item.tasks) return
    const idx = item.tasks.findIndex((t) => t.id === taskId)
    if (idx === -1) return
    const removed = item.tasks.splice(idx, 1)
    const task = removed[0]
    if (!task) return
    const destIndices: number[] = []
    item.tasks.forEach((t, i) => {
      if (t.kanban_column_id === columnId) destIndices.push(i)
    })
    const at = Math.max(0, Math.min(Math.floor(position), destIndices.length))
    const insertIdx = at === destIndices.length ? item.tasks.length : destIndices[at]!
    item.tasks.splice(insertIdx, 0, task)
  }

  // Move a task to a different column and/or position.
  async function moveTaskToColumn(
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId: string,
    position: number,
    force = false,
  ): Promise<void> {
    // Awaits the API BEFORE mutating: a 409 move-gate refusal throws here with local state untouched, so the card stays in its original column (the ApiError body …
    await api.moveTask(workspaceId, itemId, taskId, columnId, position, force)
    const item = findItem(workspaceId, itemId)
    if (item && item.tasks) {
      const task = item.tasks.find((t) => t.id === taskId)
      if (task) {
        task.kanban_column_id = columnId
        task.kanban_position = position
        placeTaskAtColumnPosition(item, taskId, columnId, position)
        await cacheTaskMutation(workspaceId, itemId, task, columnId)
      }
    }
    // Local-mutation dedupe (same pattern as design drags): the backend fans the `kanban_task moved` SSE event back to the mover too, and the kanbanSse handler …
    registerRecentLocalMutations([taskId], Date.now() + RECENT_MUTATION_TTL_MS)
  }

  // Mirror a kanban task's column (and optional position) into the local store WITHOUT an HTTP round-trip.Contract: - `newColumnId`: the destination column id …
  function mirrorKanbanTaskMove(
    workspaceId: string,
    itemId: string,
    taskId: string,
    newColumnId: string | null,
    newPosition?: number,
  ): void {
    const item = findItem(workspaceId, itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return
    task.kanban_column_id = newColumnId
    if (newPosition !== undefined) {
      task.kanban_position = newPosition
    }
    if (newColumnId !== null && newColumnId.length > 0 && newPosition !== undefined) {
      placeTaskAtColumnPosition(item, taskId, newColumnId, newPosition)
    }
    void cacheTaskMutation(workspaceId, itemId, task, newColumnId ?? undefined)
  }

  // Patch a task's `needs_human_review` flag IN PLACE (zero network).
  function applyHumanTouched(
    workspaceId: string,
    itemId: string,
    taskId: string,
    needsHumanReview: boolean,
  ): void {
    const item = findItem(workspaceId, itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return
    task.needs_human_review = needsHumanReview
    void cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
  }

  return {
    moveTaskToColumn,
    // NEW (sse-kanban-move-duplicate-task plan, 2026-08-06): SSE handler calls this BEFORE triggering the refetch on a kanban_task move/assign/unassign event so the …
    mirrorKanbanTaskMove,
    // NEW (chatview-open api-spam fix, 2026-08-24): in-place needs_human_review patch for `human_touched` SSE events — replaces the 7× tasks?limit=100 refetch that …
    applyHumanTouched,
  }
}
