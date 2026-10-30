import { TaskEngineDb, type TaskRequest } from '../../sync/TaskEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../../sync/runtime'
import { normalizeTaskTags } from './normalize'
import type { Task, WorkspaceItem } from './types'

export function createTaskCache() {
  const taskEngineDb = new TaskEngineDb()

  function taskRequest(
    workspaceId: string,
    itemId: string,
    columnId?: string,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): TaskRequest {
    return {
      workspaceId,
      itemId,
      ...(columnId ? { columnId } : {}),
      ...(q ? { q } : {}),
      ...(sortBy ? { sortBy } : {}),
      ...(direction ? { direction } : {}),
    }
  }

  function taskCacheContexts(
    workspaceId: string,
    itemId: string,
    columnId?: string,
  ): TaskRequest[] {
    return [taskRequest(workspaceId, itemId, columnId), taskRequest(workspaceId, itemId)]
  }

  function replaceItemTasksForColumn(item: WorkspaceItem, columnId: string, rows: Task[]): void {
    const normalized = rows.map(normalizeTaskTags)
    const freshIds = new Set(normalized.map((task) => task.id))
    const otherTasks = (item.tasks ?? []).filter(
      (task) => task.kanban_column_id !== columnId && !freshIds.has(task.id),
    )
    item.tasks = [...otherTasks, ...normalized]
  }

  async function cacheTaskMutation(
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ): Promise<void> {
    await runSyncVoid(
      taskEngineDb.putTaskInContexts(taskCacheContexts(workspaceId, itemId, columnId), task),
      'tasks.putTaskInContexts',
    )
  }

  // Evict one task from every cache context it could live in (the
  // task's column context plus the board-wide context). Every cache
  // write goes through taskCacheContexts, so these two cover it.
  async function removeTaskFromCache(
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId?: string,
  ): Promise<void> {
    for (const request of taskCacheContexts(workspaceId, itemId, columnId)) {
      await runSyncVoid(taskEngineDb.removeTask(request, taskId), 'tasks.removeTask')
    }
  }

  async function primeTaskCache(
    workspaceId: string,
    itemId: string,
    columnId: string | undefined,
    limit: number,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<Task[]> {
    const request = taskRequest(workspaceId, itemId, columnId, q, sortBy, direction)
    const rows = await runSyncEffectOr(
      taskEngineDb.primeFromCache(request, limit),
      [],
      'tasks.primeFromCache',
    )
    return rows.map((row) => normalizeTaskTags(row.raw))
  }

  async function revalidateTaskCache(
    workspaceId: string,
    itemId: string,
    columnId: string | undefined,
    limit: number,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<{ tasks: Task[]; has_more: boolean; next_cursor: string | null } | null> {
    const request = taskRequest(workspaceId, itemId, columnId, q, sortBy, direction)
    const delta = await runSyncEffect(taskEngineDb.loadDelta(request, limit), 'tasks.loadDelta')
    if (!delta) return null
    return {
      tasks: delta.items.map((row) => normalizeTaskTags(row.raw)),
      has_more: delta.hasMore,
      next_cursor: delta.paginationCursor,
    }
  }

  return {
    taskEngineDb,
    taskRequest,
    taskCacheContexts,
    replaceItemTasksForColumn,
    cacheTaskMutation,
    removeTaskFromCache,
    primeTaskCache,
    revalidateTaskCache,
  }
}
