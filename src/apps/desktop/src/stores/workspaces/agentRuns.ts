import * as api from '../../api'

export function createAgentRuns() {
  // Manually fire a workspace routine. Returns the backend's `{ session_id }` on success, or
  // `undefined` on failure (the caller's responsibility to navigate / show an error). We
  // deliberately do NOT navigate here — that's a UI concern owned by the RoutineView.
  async function runRoutineItem(
    workspaceId: string,
    itemId: string,
    routineId: string,
  ): Promise<{ session_id: string } | undefined> {
    try {
      return await api.runWorkspaceRoutine(workspaceId, itemId, routineId)
    } catch (err) {
      console.error('Failed to run routine:', err)
      return undefined
    }
  }

  // Kanban "Start agent" flow.
  async function startAgentOnTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<{ success: boolean; session_id?: string; status?: string } | undefined> {
    try {
      return await api.startAgentOnTask(workspaceId, itemId, taskId)
    } catch (err) {
      console.error('Failed to start agent on task:', err)
      return undefined
    }
  }

  // Column "Run all agents" flow.
  async function runAllAgentsInColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<api.RunAllAgentsSummary> {
    try {
      return await api.runAllAgentsInColumn(workspaceId, itemId, columnId)
    } catch (err) {
      console.error('Failed to run all agents in column:', err)
      return { success: false, started: [], skipped: [], failed: [] }
    }
  }

  // Column "Stop all agents" flow — the mirror of `runAllAgentsInColumn` above. Thin wrapper around
  // api.stopAllAgentsInColumn (POST .../kanban/columns/:columnId/stop_all_agents) so KanbanView
  // doesn't import the wire shape directly.
  async function stopAllAgentsInColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<api.StopAllAgentsSummary> {
    try {
      return await api.stopAllAgentsInColumn(workspaceId, itemId, columnId)
    } catch (err) {
      console.error('Failed to stop all agents in column:', err)
      return { success: false, stopped: [], skipped: [], failed: [] }
    }
  }

  // Kanban "create task & run agent" flow. Wraps api.sendChatMessage
  // so KanbanView doesn't import the wire shape directly.
  async function runAgentOnNewTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    params: {
      queueMessage: string
      cwd: string
      isAutoRetryUntilStop?: '0' | '1'
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty / undefined = backend default
      // ("Default (top-level config)"). When set, the chatview's picker will reflect the chosen
      // profile immediately on landing.
      selectedAgent?: string
      // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
      // 2026-08-06-kanban-image-attach-in-chatview). Base64 data URLs of images the user pasted in
      // the create-mode description.
      imageUrls?: string[]
      videoUrls?: string[]
    },
  ): Promise<{ status: string } | undefined> {
    try {
      return await api.sendChatMessage(
        taskId,
        params.queueMessage,
        params.cwd,
        params.imageUrls, // was: undefined (bug — see plan)
        params.selectedAgent ?? '', // CHANGED — was ''
        params.isAutoRetryUntilStop ?? '', // forwards '1' when toggle ON, else ''
        params.videoUrls, // Migration 090 — clips ride video_urls
      )
    } catch (err) {
      console.error('Failed to run agent on new task:', err)
      return undefined
    }
  }

  return {
    runRoutineItem,
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Triggers a worker on an existing
    // task's session without queueing a new user message. Sibling of runAgentOnNewTask
    // (create-time) and runRoutineItem (workspace-routine manual fire).
    startAgentOnTask,
    // NEW (plan: 2026-09-09-run-all-agents-by-column, Task 4, Option C).
    // Bulk run for one column — server owns the task list.
    runAllAgentsInColumn,
    // Bulk stop for one column — the mirror of runAllAgentsInColumn.
    stopAllAgentsInColumn,
    runAgentOnNewTask,
  }
}
