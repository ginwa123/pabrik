import type { Ref } from 'vue'
import * as api from '../../api'
import { useNavigationStore } from '../navigation'
import { normalizeTaskTags } from './normalize'
import type { Task, Workspace } from './types'

interface TaskEditParams {
  workspaces: Ref<Workspace[]>
  activeTaskId: Ref<string | null>
  cacheTaskMutation: (
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ) => Promise<void>
}

export function createTaskEdit(p: TaskEditParams) {
  const { workspaces, activeTaskId, cacheTaskMutation } = p

  /** Pin or unpin a task and persist the change via `POST /api/.../tasks/:task_id/pin`. Optimistic:
   * the local task's `is_pinned` flag is flipped immediately and the `pinned_position` is bumped to
   * MAX+1 (matching the backend's behavior). */
  async function pinTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    isPinned: boolean,
  ): Promise<{ success: boolean; pinned_position: number } | undefined> {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return undefined
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return undefined
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return undefined

    // Snapshot for rollback.
    const previousIsPinned = task.is_pinned ?? false
    const previousPinnedPosition = task.pinned_position ?? 0

    // Compute the optimistic pinned_position. When pinning, bump to MAX+1 across the item's
    // currently-pinned tasks (excluding the row being pinned — its current value would otherwise be
    // the new MAX). When unpinning, reset to 0 (the value is irrelevant for unpinned rows).
    let optimisticPosition = previousPinnedPosition
    if (isPinned) {
      const maxPinned = item.tasks.reduce<number>((acc, t) => {
        if (t.id === taskId) return acc
        const p = t.pinned_position ?? 0
        return p > acc ? p : acc
      }, -1)
      optimisticPosition = maxPinned + 1
    }

    task.is_pinned = isPinned
    task.pinned_position = optimisticPosition

    try {
      const result = await api.pinTask(workspaceId, itemId, taskId, isPinned)
      // The backend may assign a different pinned_position if a
      // concurrent pin raced with ours. Echo the backend's value.
      if (result.pinned_position !== undefined) {
        task.pinned_position = result.pinned_position
      }
      await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      return { success: true, pinned_position: result.pinned_position }
    } catch (err) {
      console.error('[workspacesStore.pinTask] API call failed, rolling back:', err)
      task.is_pinned = previousIsPinned
      task.pinned_position = previousPinnedPosition
      return undefined
    }
  }

  /** Reorder the pinned subset of a single workspace item and persist the new order via `POST
   * /api/.../tasks/reorder_pinned`. Optimistic: the item's pinned tasks are reordered in the local
   * array immediately so the UI snaps on drop. */
  async function reorderPinnedTasks(workspaceId: string, itemId: string, orderedIds: string[]) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const currentPinned = item.tasks.filter((t) => t.is_pinned)
    if (currentPinned.length === 0) return

    if (orderedIds.length !== currentPinned.length) {
      console.error(
        `[workspacesStore.reorderPinnedTasks] orderedIds length ${orderedIds.length} != current pinned ${currentPinned.length}; refusing reorder`,
      )
      return
    }

    // Snapshot for rollback.
    const previousOrder = item.tasks.slice()

    // Optimistic local reorder: rebuild the tasks array as [ordered pinned rows in the new order,
    // ...unpinned rows]. Unpinned rows keep their existing relative order (the unpinned-region
    // ORDER BY is unchanged by the reorder).
    const pinnedById = new Map(currentPinned.map((t) => [t.id, t]))
    const reorderedPinned: Task[] = []
    for (const id of orderedIds) {
      const t = pinnedById.get(id)
      if (t) reorderedPinned.push(t)
    }
    // Defensive: any pinned rows missed in the payload are
    // appended at the end (should not happen given the length
    // check).
    for (const t of currentPinned) {
      if (!orderedIds.includes(t.id)) reorderedPinned.push(t)
    }
    const unpinned = item.tasks.filter((t) => !t.is_pinned)
    item.tasks = [...reorderedPinned, ...unpinned]

    try {
      await api.reorderPinnedTasks(workspaceId, itemId, orderedIds)
      for (const task of reorderedPinned) {
        await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      }
    } catch (err) {
      console.error('[workspacesStore.reorderPinnedTasks] API call failed, rolling back:', err)
      item.tasks = previousOrder
    }
  }

  // Rename a task. Cascades to the linked session via the backend (`updateTaskName` in
  // llm_history.zig, then onEventSendSessions SSE broadcast) so the ChatsList picks up the new
  // name. Mirrors the optimistic-update + rollback pattern from `renameWorkspace`.
  async function renameTask(workspaceId: string, itemId: string, taskId: string, newName: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    const trimmed = newName.trim()
    if (!trimmed || trimmed === task.name) return

    const previousName = task.name
    // Optimistic update
    task.name = trimmed

    // Keep the chat-view / chat-list header in sync if this is the
    // active task.
    const wasActive = activeTaskId.value === taskId
    if (wasActive) {
      useNavigationStore().setActiveChatName(trimmed)
    }

    // Sync with API. The backend PUT /api/workspaces/tasks/:task_id
    // cascades the rename to the linked session row and broadcasts
    // a session.updated SSE event (see backend tasks_update.zig).
    try {
      await api.updateTaskSimple(taskId, { name: trimmed })
      await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
    } catch (err) {
      console.error('Failed to rename task:', err)
      // Rollback on error
      task.name = previousName
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
    }
  }

  // Update a task's name AND/OR description in a single round-trip (kanban-task-detail-dialog plan,
  // Chunk 2). Mirrors the optimistic-update + rollback pattern from `renameTask`. The patch object
  // only includes fields the caller actually sent — missing fields are left unchanged server-side.
  async function updateTaskDetails(
    workspaceId: string,
    itemId: string,
    taskId: string,
    fields: {
      name?: string
      description?: string
      tags?: string[]
      // NEW (kanban task dependencies). Replace-all edit: `[]` clears all; undefined = leave untouched.
      depends_on?: string[]
      // NEW (Migration 069 — kanban image urls column). Empty array = clear all images; undefined =
      // leave unchanged.
      imageUrls?: string[]
      // NEW (Migration 090 — kanban video urls column). Same
      // contract as imageUrls.
      videoUrls?: string[]
    },
  ) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    // Build the patch — only include fields the caller actually sent.
    // A no-op patch (all undefined) is rejected early so we don't
    // burn an API call.
    const patch: {
      name?: string
      description?: string
      tags?: string[]
      depends_on?: string[]
      imageUrls?: string[]
      videoUrls?: string[]
    } = {}
    if (fields.name !== undefined) {
      const trimmed = fields.name.trim()
      if (!trimmed) return // empty name is never a valid update
      patch.name = trimmed
    }
    if (fields.description !== undefined) {
      patch.description = fields.description
    }
    // Migration 067 — kanban task tags. Empty array = clear all tags; undefined = leave unchanged.
    // The api.updateTaskSimple helper detects `tags !== undefined` and JSON-encodes the array for
    // the wire; the backend validates + persists.
    if (fields.tags !== undefined) {
      patch.tags = fields.tags
    }
    // Dependencies: replace-all; `[]` clears, undefined skips.
    if (fields.depends_on !== undefined) {
      patch.depends_on = fields.depends_on
    }
    // Migration 069 — kanban image urls. Empty array = clear all
    // images; undefined = leave unchanged. The api.updateTaskSimple
    // helper `||`-joins the array for the wire.
    if (fields.imageUrls !== undefined) {
      patch.imageUrls = fields.imageUrls
    }
    // Migration 090 — kanban video urls. Same contract as imageUrls.
    if (fields.videoUrls !== undefined) {
      patch.videoUrls = fields.videoUrls
    }
    if (Object.keys(patch).length === 0) return

    // Optimistic update — capture previous values for rollback.
    const previousName = task.name
    const previousDescription = task.description
    const previousTags = task.tags
    const previousDependsOn = task.depends_on
    const previousImageUrls = task.imageUrls
    const previousVideoUrls = task.videoUrls
    if (patch.name !== undefined) task.name = patch.name
    if (patch.description !== undefined) task.description = patch.description
    if (patch.tags !== undefined) task.tags = patch.tags
    if (patch.depends_on !== undefined) task.depends_on = patch.depends_on
    if (patch.imageUrls !== undefined) {
      task.imageUrls = patch.imageUrls
      task.is_have_image = patch.imageUrls.length > 0
    }
    if (patch.videoUrls !== undefined) {
      task.videoUrls = patch.videoUrls
      task.is_have_video = patch.videoUrls.length > 0
    }

    // Keep the chat-view / chat-list header in sync if this is the
    // active task and a name change is part of the patch.
    const wasActive = activeTaskId.value === taskId
    if (wasActive && patch.name !== undefined) {
      useNavigationStore().setActiveChatName(patch.name)
    }

    try {
      await api.updateTaskSimple(taskId, patch)
    } catch (err) {
      console.error('Failed to update task details:', err)
      // Rollback on error
      task.name = previousName
      task.description = previousDescription
      task.tags = previousTags
      task.depends_on = previousDependsOn
      task.imageUrls = previousImageUrls
      task.videoUrls = previousVideoUrls
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
      // Rethrow so the dialog can show a retry option. Mirrors the
      // renameTask contract — the dialog (Chunk 3) catches this in
      // its own Save handler.
      throw err
    }
    await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
  }

  // Refetch ONE task from the server and patch the in-store copy in place.
  async function refreshTask(workspaceId: string, itemId: string, taskId: string): Promise<void> {
    try {
      const fetched = await api.getTask(workspaceId, itemId, taskId)
      if (!fetched) return
      // Migration 067 — normalize tags from wire string to in-memory
      // string[] (also folds in image_urls splitting) before splicing
      // into the store.
      const freshTask = normalizeTaskTags(fetched)
      for (const ws of workspaces.value) {
        if (ws.id !== workspaceId) continue
        for (const item of ws.items) {
          if (item.id !== itemId) continue
          if (!item.tasks) continue
          const idx = item.tasks.findIndex((t) => t.id === taskId)
          if (idx === -1) continue
          // Replace the cached task object entirely. The Task interface is loose enough (mostly
          // optional fields) that this preserves all caller state. The dialog re-derives its local
          // form state from the new task via its watcher.
          item.tasks.splice(idx, 1, freshTask)
          await cacheTaskMutation(
            workspaceId,
            itemId,
            freshTask,
            freshTask.kanban_column_id ?? undefined,
          )
          return
        }
      }
    } catch (err) {
      console.warn('Failed to refresh task before dialog open:', err)
    }
  }

  return {
    pinTask,
    reorderPinnedTasks,
    renameTask,
    // NEW (kanban-task-detail-dialog plan, Chunk 2). Edit a task's name and/or description in one
    // API call from the detail dialog. Uses the same PUT /api/workspaces/tasks/:task_id endpoint as
    // renameTask — only the body shape is wider.
    updateTaskDetails,
    // NEW (auto-retry-until-stop fix): re-fetch a single task from the server (with the JOINed
    // is_auto_retry_until_stop column) and patch the in-store copy.
    refreshTask,
  }
}
