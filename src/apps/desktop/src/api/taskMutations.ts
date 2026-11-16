import { joinMediaUrlsWire } from '../helpers/mediaUrls'
import { apiFetch } from './client'
import { type Task, splitMediaUrls } from './tasks'

/** Create a task under a workspace item. */
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
    // Auto-retry-until-stop (Migration 063, Option A fix): when the caller passes `'1'`, the backend ALSO inserts a `sessions` row (task.id == session.id per the …
    isAutoRetryUntilStop?: string
    // Kanban task tags (Migration 067 — kanban task tags feature).
    tags?: string[]
    // NEW (Migration 069 — kanban image urls column).
    imageUrls?: string[]
    // NEW (Migration 090 — kanban video urls column).
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
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
  // Only forward the unattended flag when the user actually flipped it ON.
  if (params.isAutoRetryUntilStop === '1' && taskType === 'standard') {
    body.is_auto_retry_until_stop = '1'
  }
  // Forward tags as a JSON-encoded array string (Migration 067).
  if (params.tags && params.tags.length > 0) {
    body.tags = JSON.stringify(params.tags)
  }
  // Migration 069 — image_urls.
  {
    const { images, videos } = splitMediaUrls(params.imageUrls, params.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  // Migration 070 — per-task cwd override.
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

// Task API - Simple version (just task_id + optional fields) The backend's PUT /api/workspaces/tasks/:task_id accepts a subset of fields.
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    // NEW (kanban-task-detail-dialog plan): the per-task description shown in the detail dialog.
    description?: string
    // NEW (kanban task tags, Migration 067): array of tag strings.
    tags?: string[]
    // NEW (kanban image urls, Migration 069): array of base64 data URLs.
    imageUrls?: string[]
    // NEW (kanban video urls, Migration 090): same contract as imageUrls.
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    cwd?: string
    // NEW (kanban task dependencies). Replace-all dependency edit
    depends_on?: string[]
  },
): Promise<{ success: boolean }> {
  const body: Record<string, unknown> = { ...data }
  // Encode tags array as a JSON string for the wire (Migration 067).
  if (data.tags !== undefined) {
    body.tags = JSON.stringify(data.tags)
  }
  // Migration 069 — image_urls.
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

/** Pin or unpin a task. */
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

/** Reorder the pinned subset of a single workspace item. */
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
