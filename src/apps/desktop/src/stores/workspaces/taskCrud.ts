import type { Ref } from 'vue'
import * as api from '../../api'
import { useNotificationStore } from '../notifications'
import { normalizeTaskTags } from './normalize'
import type { Task, Workspace } from './types'

interface TaskCrudParams {
  workspaces: Ref<Workspace[]>
  activeTaskId: Ref<string | null>
  cacheTaskMutation: (
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ) => Promise<void>
  removeTaskFromCache: (
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId?: string,
  ) => Promise<void>
}

export function createTaskCrud(p: TaskCrudParams) {
  const { workspaces, activeTaskId, cacheTaskMutation, removeTaskFromCache } = p

  // Add a task to a workspace item. The third arg is a single params object. For a standard task
  // (the default), pass `{ name, description? }`.
  async function addTask(
    workspaceId: string,
    itemId: string,
    params: {
      name: string
      description?: string
      taskType?: 'standard' | 'memory'
      memory?: {
        name: string
        content: string
      }
      // Auto-retry-until-stop (Migration 063, Option A fix): when `'1'`, the backend ALSO inserts a
      // `sessions` row keyed by the new task.id so the unattended-mode flag persists from creation.
      // Forwarded only for standard tasks (memory has its own session lifecycle).
      isAutoRetryUntilStop?: string
      // NEW (Migration 067 — kanban task tags): array of free-form
      // tag strings. Forwarded to api.createTask which JSON-encodes
      // for the wire. Empty array / undefined = no tags.
      tags?: string[]
      // NEW (Migration 069 — kanban image urls column): array of base64 data URLs. Forwarded to
      // api.createTask which `||`-joins for the wire (matching `llm_history.image_url` convention).
      imageUrls?: string[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Forwarded to
      // api.createTask as `cwd` on the wire. Absolute path on disk or '' for cwd-less.
      cwd?: string
    },
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return undefined

    if (!item.tasks) {
      item.tasks = []
    }

    const taskType: 'standard' | 'memory' = params.taskType ?? 'standard'

    try {
      const newTask = await api.createTask(workspaceId, itemId, {
        name: params.name,
        description: params.description,
        taskType,
        memory: params.memory,
        isAutoRetryUntilStop: params.isAutoRetryUntilStop,
        // Migration 067 — pass tags through.
        tags: params.tags,
        // Migration 069 — pass image_urls through (the api helper
        // `||`-joins the array for the wire).
        imageUrls: params.imageUrls,
        // Migration 070 — pass the per-task cwd through (absolute path on disk or '' for cwd-less).
        // The api helper forwards verbatim; the backend's validated_cwd block re-validates
        // (absolute, ≤ 4 KiB, no control chars) before INSERT.
        cwd: params.cwd,
      })
      item.tasks.unshift(newTask)
      await cacheTaskMutation(workspaceId, itemId, newTask, newTask.kanban_column_id ?? undefined)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails. Match the pre-existing fallback contract (returns
      // a taskId, populates the item's tasks list) and now also carry task_type + memory so the
      // offline UI still branches correctly.
      const taskId = `task-${Date.now()}`
      item.tasks.unshift({
        id: taskId,
        name: params.name,
        description: params.description,
        task_type: taskType,
        memory_name: params.memory?.name,
        is_auto_retry_until_stop: params.isAutoRetryUntilStop,
        completed: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      })
      return taskId
    }
  }

  // Kanban-specific task create.
  async function addKanbanTask(
    workspaceId: string,
    itemId: string,
    mode: 'create' | 'create_session' | 'create_and_run',
    params: {
      name: string
      description?: string
      queue_message?: string
      tags?: string[]
      imageUrls?: string[]
      videoUrls?: string[]
      cwd?: string
      isAutoRetryUntilStop?: string
      selected_profile_model?: string
      /** Migration 112 — the skills this task asks the agent to use, in pick order. */
      skillNames?: string[]
    },
  ): Promise<api.KanbanCreateResponse> {
    const wirePayload:
      | api.KanbanCreateTaskPayload
      | api.KanbanCreateSessionOnlyPayload
      | api.KanbanCreateAndRunPayload =
      mode === 'create_and_run'
        ? {
            mode: 'create_and_run',
            name: params.name,
            description: params.description,
            queue_message: params.queue_message ?? '',
            tags: params.tags,
            imageUrls: params.imageUrls,
            videoUrls: params.videoUrls,
            cwd: params.cwd,
            isAutoRetryUntilStop: params.isAutoRetryUntilStop,
            selected_profile_model: params.selected_profile_model,
            skill_names: params.skillNames,
          }
        : mode === 'create_session'
          ? {
              mode: 'create_session',
              name: params.name,
              description: params.description,
              tags: params.tags,
              imageUrls: params.imageUrls,
              videoUrls: params.videoUrls,
              cwd: params.cwd,
              isAutoRetryUntilStop: params.isAutoRetryUntilStop,
              // Persists on the new sessions row (see Task 2's
              // KanbanCreateSessionOnlyPayload comment in api/index.ts).
              selected_profile_model: params.selected_profile_model,
              skill_names: params.skillNames,
            }
          : {
              mode: 'create',
              name: params.name,
              description: params.description,
              tags: params.tags,
              imageUrls: params.imageUrls,
              videoUrls: params.videoUrls,
              cwd: params.cwd,
              isAutoRetryUntilStop: params.isAutoRetryUntilStop,
              skillNames: params.skillNames,
            }

    try {
      const res = await api.createKanbanTask(workspaceId, itemId, wirePayload)
      // Media-flags change — the create response carries only `is_have_image` / `is_have_video`
      // flags (no base64 payload). Normalize in place for tags/dates; the detail dialog lazy-loads
      // media via fetchTaskMedia when a flag is true.
      if (res.task) normalizeTaskTags(res.task)
      return res
    } catch (err) {
      if (mode === 'create_and_run') {
        // Partial-success path: the backend's task INSERT may have succeeded even when the run step
        // failed (the session INSERT might have failed but the task row is still there). Surface
        // the error as a toast so the user can click the card to retry.
        const msg = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError(msg, 'Task created — agent did not start')
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        return { task: null as any, session: null }
      }
      if (mode === 'create_session') {
        // Partial-success path: create_session can fail AFTER the task INSERT succeeded (rare — the
        // sessions INSERT or session_created SSE emit failed).
        const msg = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError(msg, 'Task created — session init failed')
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        return { task: null as any, session: null }
      }
      throw err
    }
  }

  // Toggle task completion
  async function toggleTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const task = item.tasks.find((t) => t.id === taskId)
    if (task) {
      task.completed = !task.completed
      // Sync with API
      try {
        await api.updateTask(workspaceId, itemId, taskId, { completed: task.completed })
        await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      } catch (err) {
        console.error('Failed to update task:', err)
        // Revert on error
        task.completed = !task.completed
      }
    }
  }

  // Delete a task
  async function deleteTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    // Store reference for potential rollback
    const taskIndex = item.tasks.findIndex((t) => t.id === taskId)
    if (taskIndex === -1) return

    const deletedTask = item.tasks[taskIndex]
    item.tasks = item.tasks.filter((t) => t.id !== taskId)

    // Clear active task if it was the deleted one
    if (activeTaskId.value === taskId) {
      activeTaskId.value = null
    }

    // Sync with API
    try {
      await api.deleteTask(workspaceId, itemId, taskId)
      await removeTaskFromCache(
        workspaceId,
        itemId,
        taskId,
        deletedTask?.kanban_column_id ?? undefined,
      )
    } catch (err) {
      console.error('Failed to delete task:', err)
      // Rollback on error
      if (deletedTask) {
        item.tasks.splice(taskIndex, 0, deletedTask)
        await cacheTaskMutation(
          workspaceId,
          itemId,
          deletedTask,
          deletedTask.kanban_column_id ?? undefined,
        )
      }
    }
  }

  return {
    addTask,
    addKanbanTask,
    toggleTask,
    deleteTask,
  }
}
