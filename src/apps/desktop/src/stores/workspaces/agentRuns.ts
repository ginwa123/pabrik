import * as api from '../../api'

export function createAgentRuns() {
  // Manually fire a workspace routine.
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

  // Column "Stop all agents" flow — the mirror of `runAllAgentsInColumn` above.
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

  // Kanban "create task & run agent" flow.
  async function runAgentOnNewTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    params: {
      queueMessage: string
      cwd: string
      isAutoRetryUntilStop?: '0' | '1'
      // NEW (plan: 2026-08-06-kanban-task-profile-selector).
      selectedAgent?: string
      // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces 2026-08-06-kanban-image-attach-in-chatview).
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
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
    startAgentOnTask,
    // NEW (plan: 2026-09-09-run-all-agents-by-column, Task 4, Option C).
    runAllAgentsInColumn,
    // Bulk stop for one column — the mirror of runAllAgentsInColumn.
    stopAllAgentsInColumn,
    runAgentOnNewTask,
  }
}
