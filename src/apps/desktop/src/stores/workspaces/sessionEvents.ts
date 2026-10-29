import type { Ref } from 'vue'
import * as api from '../../api'
import { useSseBus } from '../../helpers/sseBus'
import { useNavigationStore } from '../navigation'
import type { Task, Workspace } from './types'

interface SessionEventsParams {
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

export function createSessionEvents(p: SessionEventsParams) {
  const { workspaces, activeTaskId, cacheTaskMutation, removeTaskFromCache } = p

  // ─── Session events via sseBus ───────────────────────────────────────────── The backend cascade
  // for task rename (updateTaskName → updateSessionName → onEventSendSessions → SSE
  // session.updated) emits a `session.updated` event on `/api/sessions/stream`.
  let sessionHandlersInstalled = false

  /** Subscribe to session events. The callback fires once per session event (after the internal
   * workspacesStore handler runs). Returns an unsubscribe function. */
  function onSessionEvent(cb: (event: api.SessionEvent) => void): () => void {
    const bus = useSseBus()
    return bus.on('session', (event) => {
      try {
        cb(event)
      } catch (e) {
        // Swallow subscriber errors so a buggy callback can't take down sibling subscribers (the
        // bus's own dispatch already wraps the listener call in try/catch — this is defense in
        // depth: it also covers the case where a future bus implementation drops that wrapping).
        console.error('[workspacesStore] session event subscriber threw:', e)
      }
    })
  }

  function installSessionEventHandlers() {
    if (sessionHandlersInstalled) {
      // Already installed — don't double-register on HMR.
      return
    }
    sessionHandlersInstalled = true

    const bus = useSseBus()
    bus.on('session', (event) => {
      if (event.action === 'updated') {
        // Find the task (task.id == session_id) and update its name + unattended flag. We also keep
        // navigationStore.activeChatName in sync if the renamed task is active — this is the same
        // pattern as renameTask (workspaces.ts:renameTask).
        for (const ws of workspaces.value) {
          for (const item of ws.items) {
            if (!item.tasks) continue
            const task = item.tasks.find((t) => t.id === event.id)
            if (task) {
              task.name = event.name || task.name
              if (event.is_auto_retry_until_stop !== undefined) {
                task.is_auto_retry_until_stop = event.is_auto_retry_until_stop
              }
              if (activeTaskId.value === task.id) {
                useNavigationStore().setActiveChatName(task.name)
              }
              void cacheTaskMutation(ws.id, item.id, task, task.kanban_column_id ?? undefined)
              return
            }
          }
        }
      } else if (event.action === 'deleted') {
        // Find and remove the task. If it was active, clear the
        // active state so the chat view doesn't render a stale
        // task id.
        for (const ws of workspaces.value) {
          for (const item of ws.items) {
            if (!item.tasks) continue
            const idx = item.tasks.findIndex((t) => t.id === event.id)
            if (idx !== -1) {
              const doomed = item.tasks[idx]
              item.tasks.splice(idx, 1)
              if (activeTaskId.value === event.id) {
                activeTaskId.value = null
              }
              if (doomed) {
                void removeTaskFromCache(
                  ws.id,
                  item.id,
                  event.id,
                  doomed.kanban_column_id ?? undefined,
                )
              }
              return
            }
          }
        }
      }
      // 'created' events are deliberately ignored here: tasks are only ever created via POST
      // /workspaces/:w/items/:i/tasks (which the addTask action handles directly). A 'created' SSE
      // event for an unbound session is a no-op for the workspace tree.
    })
  }

  return { onSessionEvent, installSessionEventHandlers }
}
