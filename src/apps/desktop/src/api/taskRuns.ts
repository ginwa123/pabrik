import { joinMediaUrlsWire } from '../helpers/mediaUrls'
import { apiFetch } from './core'
import { type Task, splitMediaUrls } from './tasks'

/** Kanban-specific task create endpoint. */
export type KanbanCreateMode = 'create' | 'create_session' | 'create_and_run'

export interface KanbanCreateTaskPayload {
  mode: 'create'
  name: string
  description?: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  // Migration 070 — per-task cwd override. Absolute path on disk or '' for cwd-less.
  cwd?: string
  // Migration 063 — only meaningful for create_and_run; for plain create,
  // the backend atomically inserts the sessions row when this is '1'.
  isAutoRetryUntilStop?: string
  // Migration 112 — the skills this task asks the agent to use, in pick
  // order. The exact `skills.name` values from the New-task dialog's picker.
  // Persisted on the task row; empty/undefined = no skill.
  skillNames?: string[]
}

export interface KanbanCreateAndRunPayload {
  mode: 'create_and_run'
  name: string
  description?: string
  /** Required when mode='create_and_run'. The first user message the agent sees. */
  queue_message: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  cwd?: string
  isAutoRetryUntilStop?: string
  /** Backend persists onto the sessions row. Empty/undefined = backend default. */
  selected_profile_model?: string
  /** Migration 112 — the skills this task asks the agent to use, in pick order. */
  skill_names?: string[]
}

/** New mode (`create_session`) — inserts the sessions row keyed by task.id + persists
 * selected_profile_model + emits session_created SSE, but does NOT call emit_run_agent. Returns
 * `session: { id, name, status: 'idle' }`. */
export interface KanbanCreateSessionOnlyPayload {
  mode: 'create_session'
  name: string
  description?: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  /** Migration 070 — per-task cwd override. */
  cwd?: string
  /** Migration 063 — persists on the sessions row. */
  isAutoRetryUntilStop?: string
  /** Persists on the sessions row. Empty/undefined = backend default. */
  selected_profile_model?: string
  /** Migration 112 — the skills this task asks the agent to use, in pick order. */
  skill_names?: string[]
}

export interface KanbanSessionInfo {
  id: string
  name: string
  status: string
}

export interface KanbanCreateResponse {
  task: Task
  session: KanbanSessionInfo | null
}

export async function createKanbanTask(
  workspaceId: string,
  itemId: string,
  payload: KanbanCreateTaskPayload | KanbanCreateSessionOnlyPayload | KanbanCreateAndRunPayload,
): Promise<KanbanCreateResponse> {
  const body: Record<string, unknown> = {
    mode: payload.mode,
    name: payload.name,
    description: payload.description,
  }
  if (payload.tags && payload.tags.length > 0) {
    body.tags = JSON.stringify(payload.tags)
  }
  {
    const { images, videos } = splitMediaUrls(payload.imageUrls, payload.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  if (payload.cwd !== undefined) {
    body.cwd = payload.cwd
  }
  if (payload.isAutoRetryUntilStop !== undefined) {
    body.is_auto_retry_until_stop = payload.isAutoRetryUntilStop
  }
  const skill_names: string[] | undefined =
    payload.mode === 'create'
      ? payload.skillNames
      : (payload as { skill_names?: string[] }).skill_names
  if (skill_names !== undefined) {
    body.skill_names = skill_names
  }
  if (payload.mode === 'create_and_run') {
    body.queue_message = payload.queue_message
    if (payload.selected_profile_model !== undefined) {
      body.selected_profile_model = payload.selected_profile_model
    }
  } else if (payload.mode === 'create_session') {
    // Persists on the new sessions row.
    if (payload.selected_profile_model !== undefined) {
      body.selected_profile_model = payload.selected_profile_model
    }
  }
  return apiFetch<KanbanCreateResponse>(`/workspaces/${workspaceId}/items/${itemId}/kanban/tasks`, {
    method: 'POST',
    body,
  })
}

/** Manually fire a workspace routine. Returns the session_id (which equals the routine id — every
 * fire appends to the same session chat). */
export async function runWorkspaceRoutine(
  workspaceId: string,
  itemId: string,
  routineId: string,
): Promise<{ session_id: string }> {
  return await apiFetch<{ session_id: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/routines/${routineId}/run`,
    { method: 'POST' },
  )
}

/** Trigger an LLM worker on an existing task's session WITHOUT queueing a new user message. For
 * tasks with chat history, the agent resumes the conversation. */
export async function startAgentOnTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean; session_id?: string; status?: string }> {
  return await apiFetch<{ success: boolean; session_id?: string; status?: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/start_agent`,
    { method: 'POST' },
  )
}

/** Bulk "Run all agents" for one kanban column. */
export interface RunAllAgentsSummary {
  success: boolean
  column_id?: string
  started: string[]
  skipped: string[]
  failed: string[]
}

export async function runAllAgentsInColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<RunAllAgentsSummary> {
  return await apiFetch<RunAllAgentsSummary>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}/run_all_agents`,
    { method: 'POST' },
  )
}

/** Bulk "Stop all agents" for one kanban column — the mirror of `runAllAgentsInColumn` above. */
export interface StopAllAgentsSummary {
  success: boolean
  column_id?: string
  stopped: string[]
  skipped: string[]
  failed: string[]
}

export async function stopAllAgentsInColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<StopAllAgentsSummary> {
  return await apiFetch<StopAllAgentsSummary>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}/stop_all_agents`,
    { method: 'POST' },
  )
}
