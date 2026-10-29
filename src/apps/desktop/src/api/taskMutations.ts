import { joinMediaUrlsWire } from '../helpers/mediaUrls'
import { apiFetch } from './core'
import { type Task, splitMediaUrls } from './tasks'

/** Create a task under a workspace item. The third arg is a single params object: for a standard
 * task pass `{ name, description?, taskType: 'standard' }`, for a memory pass `{ name, taskType:
 * 'memory', memory: { name, content } }`. */
export async function createTask(
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
    // Auto-retry-until-stop (Migration 063, Option A fix): when the caller passes `'1'`, the
    // backend ALSO inserts a `sessions` row (task.id == session.id per the project convention) so
    // the unattended-mode flag has somewhere to land at create time.
    isAutoRetryUntilStop?: string
    // Kanban task tags (Migration 067 — kanban task tags feature). Array of free-form tag strings.
    // Empty array / undefined = no tags. Forwarded as a JSON-encoded array string on the wire.
    tags?: string[]
    // NEW (Migration 069 — kanban image urls column). NOTE (Migration 090): may also
    // carry `data:video/...` URLs — splitMediaUrls routes those to `video_urls` at send time.
    imageUrls?: string[]
    // NEW (Migration 090 — kanban video urls column). Array of
    // base64 data URLs (`data:video/<mime>;base64,<payload>`).
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Absolute path
    // on disk or '' for cwd-less. When undefined, the backend stores NULL (cwd-less task — falls
    // back to the kanban-level path + sandbox).
    cwd?: string
  },
): Promise<Task> {
  const taskType = params.taskType ?? 'standard'
  const body: Record<string, unknown> = {
    name: params.name,
    description: params.description,
    task_type: taskType,
  }
  if (taskType === 'memory' && params.memory) {
    body.memory_name = params.memory.name
    body.memory_content = params.memory.content
  }
  // Only forward the unattended flag when the user actually flipped
  // it ON. Default '0' is the no-op default — sending it would
  // trigger an unnecessary session INSERT (a new row per task).
  if (params.isAutoRetryUntilStop === '1' && taskType === 'standard') {
    body.is_auto_retry_until_stop = '1'
  }
  // Forward tags as a JSON-encoded array string (Migration 067). The backend's
  // tags_validation.validateAndNormalizeTags parses and re-encodes the array, so the wire shape is
  // a JSON string, not an array — single source of truth for JSON shape.
  if (params.tags && params.tags.length > 0) {
    body.tags = JSON.stringify(params.tags)
  }
  // Migration 069 — image_urls. The wire shape is a `||`-delimited string (matching
  // `llm_history.image_url`). Migration 090 — split data:video/... out to video_urls.
  {
    const { images, videos } = splitMediaUrls(params.imageUrls, params.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  // Migration 070 — per-task cwd override. Forward verbatim (the backend's `validated_cwd` block
  // validates it — absolute path, ≤ 4 KiB, no control chars).
  if (params.cwd !== undefined) {
    body.cwd = params.cwd
  }
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    body,
  })
}

export async function updateTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  data: Partial<Task>,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}

// Task API - Simple version (just task_id + optional fields) The backend's PUT
// /api/workspaces/tasks/:task_id accepts a subset of fields. The server cascades any name change to
// the linked session and re-broadcasts via SSE.
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    // NEW (kanban-task-detail-dialog plan): the per-task description
    // shown in the detail dialog. Empty string = clear (the
    // dialog's "Clear description" path sends `''`).
    description?: string
    // NEW (kanban task tags, Migration 067): array of tag strings.
    // Forwarded as JSON-encoded string. Empty array = clear tags.
    tags?: string[]
    // NEW (kanban image urls, Migration 069): array of base64 data URLs. Forwarded as
    // `||`-delimited string (matching the `llm_history.image_url` convention). Empty array = clear
    // images. Plan: docs/superpowers/plans/2026-08-06-kanban-image- urls-column.md.
    imageUrls?: string[]
    // NEW (kanban video urls, Migration 090): same contract as imageUrls.
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Semantics: -
    // undefined: leave unchanged (no-op). - '': clear per-task cwd (falls back to kanban-level path
    // + sandbox). - '/home/me/repo-A': set per-task cwd to this path.
    cwd?: string
    // NEW (kanban task dependencies). Replace-all dependency edit:
    // forwarded ONLY when provided (omitted = untouched, `[]` =
    // clear all). Sent as a real JSON array (unlike tags).
    depends_on?: string[]
  },
): Promise<{ success: boolean }> {
  const body: Record<string, unknown> = { ...data }
  // Encode tags array as a JSON string for the wire (Migration 067).
  if (data.tags !== undefined) {
    body.tags = JSON.stringify(data.tags)
  }
  // Migration 069 — image_urls. `||`-join the array for the wire
  // (matching `llm_history.image_url`). Empty array → empty string
  // → SQL '' literal → DB clears the column.
  if (data.imageUrls !== undefined || data.videoUrls !== undefined) {
    const { images, videos } = splitMediaUrls(data.imageUrls, data.videoUrls)
    body.image_urls = joinMediaUrlsWire(images)
    body.video_urls = joinMediaUrlsWire(videos)
  }
  return await apiFetch<{ success: boolean }>(`/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    body,
  })
}

export async function deleteTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'DELETE' },
  )
}

/** Pin or unpin a task. The backend bumps the row's `pinned_position` to MAX+1 (when pinning) so a
 * newly-pinned task lands at the BOTTOM of the pinned region; the user can drag it to a different
 * position afterwards. */
export async function pinTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{
    success: boolean
    id: string
    is_pinned: boolean
    pinned_position: number
  }>(`/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/pin`, {
    method: 'POST',
    body: { is_pinned: isPinned },
  })
}

/** Reorder the pinned subset of a single workspace item. The `orderedIds` array is the full
 * top-to-bottom display order of the pinned rows. The backend assigns `pinned_position = count - 1
 * - i` so the rows render in the user's chosen order. */
export async function reorderPinnedTasks(
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/reorder_pinned`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}
